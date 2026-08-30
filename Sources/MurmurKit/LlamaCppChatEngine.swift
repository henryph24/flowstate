import Foundation

public enum LlamaCppError: Error, LocalizedError {
    case binaryMissing(String)
    case modelMissing(String)
    case serverTimeout
    case serverLoading
    case http(status: Int)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "llama-server not installed (run scripts/install_llama.sh)"
        case .modelMissing:
            return "Cleanup model missing (run scripts/install_llama.sh)"
        case .serverTimeout:
            return "Local cleanup model didn't start"
        case .serverLoading:
            return "Local cleanup model still loading"
        case .http(let status):
            return "Local cleanup error \(status)"
        case .emptyResponse:
            return "Empty response from local cleanup model"
        }
    }
}

/// Local cleanup LLM: spawns and owns a warm `llama-server` child (llama.cpp,
/// loopback) and speaks its OpenAI-compatible `/v1/chat/completions`. Mirrors
/// `WhisperCppEngine`'s child-server lifecycle, with one refinement: readiness
/// uses llama-server's `/health` (503 while the model loads, 200 when ready),
/// so an orphaned-but-loading server is polled instead of re-spawned. Cleanup
/// is optional, so `chatComplete` waits at most ~2s for warmth and otherwise
/// throws (`Cleaner` falls back to the raw transcript) — only `warmUp()` /
/// `ensureReady()` sit through a cold model load.
public final class LlamaCppChatEngine: ChatEngine, LocalServerEngine {
    static let warmUpPolls = 240 // × 250ms = 60s — cold GGUF load
    static let requestPolls = 8  // × 250ms = 2s — never make a paste wait

    private let binaryPath: String
    private let modelPath: String
    private let preferredPort: Int
    private var activePort: Int
    private let session: URLSession
    private var process: Process?

    public init(binaryPath: String, modelPath: String, port: Int,
                session: URLSession = LoopbackURLSession.make(resourceTimeout: 30)) {
        self.binaryPath = binaryPath
        self.modelPath = (modelPath as NSString).expandingTildeInPath
        self.preferredPort = port
        self.activePort = port
        self.session = session
    }

    deinit { shutdown() }

    public func chatComplete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await ensureServerRunning(pollBudget: Self.requestPolls)
        let request = try Self.makeChatRequest(system: system, user: user,
                                               maxTokens: maxTokens, port: activePort)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LlamaCppError.http(status: status) }
        return try Self.parseChatResponse(data)
    }

    /// Spawns the server eagerly so the model is warm before the first
    /// utterance. Safe to call repeatedly.
    public func warmUp() {
        Task.detached { [weak self] in
            try? await self?.ensureServerRunning(pollBudget: Self.warmUpPolls)
        }
    }

    /// Blocks through a full cold load — for tests/pre-flight, not the
    /// utterance path.
    public func ensureReady() async throws {
        try await ensureServerRunning(pollBudget: Self.warmUpPolls)
    }

    public func shutdown() {
        process?.terminate()
        process = nil
    }

    // MARK: server lifecycle (mirrors WhisperCppEngine, /health-aware)

    private enum Health { case ready, loading, down }

    private func health() async -> Health {
        guard let (_, response) = try? await session.data(for: Self.healthRequest(port: activePort)),
              let http = response as? HTTPURLResponse else { return .down }
        return http.statusCode == 200 ? .ready : .loading
    }

    private func ensureServerRunning(pollBudget: Int) async throws {
        // Fast path: a child WE spawned this session is already warm.
        if let running = process, running.isRunning, await health() == .ready { return }

        // Spawn/adopt only when we don't already own a running child. Never adopt
        // a listener we can't attribute to our binary (a squatter answering
        // /health would otherwise sit in the paste path); reuse a verified orphan,
        // else spawn on a private port.
        if process == nil || process?.isRunning != true {
            guard LocalServer.isSafeToExecute(binaryPath) else {
                throw LlamaCppError.binaryMissing(binaryPath)
            }
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw LlamaCppError.modelMissing(modelPath)
            }
            switch LocalServer.resolvePort(preferred: preferredPort, binaryPath: binaryPath) {
            case .adopt(let port):
                activePort = port
            case .spawn(let port):
                activePort = port
                let server = Process()
                server.executableURL = URL(fileURLWithPath: binaryPath)
                server.arguments = Self.serverArguments(modelPath: modelPath, port: activePort)
                server.standardOutput = FileHandle.nullDevice
                server.standardError = FileHandle.nullDevice
                server.environment = LocalServer.sanitizedEnvironment()
                try server.run()
                process = server
                Log.info("llama-server spawned (pid \(server.processIdentifier), port \(activePort))")
            }
        }

        for _ in 0..<pollBudget {
            if await health() == .ready { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw pollBudget < Self.warmUpPolls ? LlamaCppError.serverLoading
                                            : LlamaCppError.serverTimeout
    }

    // MARK: pure builders

    /// Deliberately minimal: llama-server treats unknown flags as fatal and
    /// the Homebrew build isn't version-pinned. The GGUF's embedded chat
    /// template is applied automatically on /v1/chat/completions. -c 4096
    /// covers the ~1,100-token cleanup system prompt plus ~865 dictated words;
    /// longer utterances error out and the Cleaner pastes the raw transcript.
    public static func serverArguments(modelPath: String, port: Int) -> [String] {
        ["-m", modelPath,
         "--host", "127.0.0.1",
         "--port", String(port),
         "-c", "4096",
         "-ngl", "99",
         "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))]
    }

    public static func healthRequest(port: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 1
        return request
    }

    public static func makeChatRequest(system: String, user: String,
                                       maxTokens: Int, port: Int) throws -> URLRequest {
        struct Message: Codable { let role: String; let content: String }
        struct Body: Codable {
            let messages: [Message]
            let temperature: Double
            let max_tokens: Int // llama.cpp's name; Groq uses max_completion_tokens
            // llama-server extension: reuse the KV cache for the shared prompt
            // prefix — the ~1,100-token system prompt would otherwise be
            // re-prefilled on every call (~1.5s per cleanup on a 3B).
            let cache_prompt: Bool
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(
            messages: [Message(role: "system", content: system),
                       Message(role: "user", content: user)],
            temperature: 0,
            max_tokens: maxTokens,
            cache_prompt: true
        ))
        // Cold prompt cache on a long utterance can exceed Groq's 10s; warm
        // calls run ~0.5–1.5s since the static system prefix stays cached.
        request.timeoutInterval = 20
        return request
    }

    public static func parseChatResponse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let content = response.choices.first?.message.content else {
            throw LlamaCppError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
