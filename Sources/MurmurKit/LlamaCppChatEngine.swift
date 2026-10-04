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

/// Local cleanup LLM: a warm `llama-server` child (llama.cpp, loopback) run by
/// `ChildServer`, speaking its OpenAI-compatible `/v1/chat/completions`.
/// `ChildServer` reuses a verified orphan, accepts a spawned child only once
/// the child holds its port, and runs one start at a time. Cleanup is
/// optional, so a dictation waits at most 2 s for the server (plus a start
/// already under way, which polls once) and otherwise throws: `Cleaner`
/// falls back to the raw transcript. Only `ensureReady()` sits through a cold
/// model load.
public final class LlamaCppChatEngine: ChatEngine, LocalServerEngine, Prewarmable {
    static let warmUpPolls = 240 // × 250ms = 60s — cold GGUF load
    static let requestPolls = 8  // × 250ms = 2s — never make a paste wait
    /// One probe: spawn the child if none runs; its model loads on its own.
    static let spawnPolls = 1

    private let binaryPath: String
    private let modelPath: String
    private let session: URLSession
    private let server: ChildServer

    public init(binaryPath: String, modelPath: String, port: Int,
                session: URLSession = LoopbackURLSession.make(resourceTimeout: 30)) {
        let model = (modelPath as NSString).expandingTildeInPath
        self.binaryPath = binaryPath
        self.modelPath = model
        self.session = session
        self.server = ChildServer(name: "llama-server", binaryPath: binaryPath,
                                  port: port, session: session) { port in
            Self.serverArguments(modelPath: model, port: port)
        }
    }

    deinit { shutdown() }

    public func chatComplete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await ensureServerRunning(polls: Self.requestPolls)
        let request = try Self.makeChatRequest(system: system, user: user,
                                               maxTokens: maxTokens, port: server.port)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LlamaCppError.http(status: status) }
        return try Self.parseChatResponse(data)
    }

    /// Spawns the server eagerly so the model is warm before the first
    /// utterance. Safe to call repeatedly.
    public func warmUp() {
        Task.detached { [weak self] in
            try? await self?.ensureServerRunning(polls: Self.spawnPolls)
        }
    }

    /// Blocks through a full cold load — for tests/pre-flight, not the
    /// utterance path.
    public func ensureReady() async throws {
        try await ensureServerRunning(polls: Self.warmUpPolls)
    }

    /// `prompt` is the cleanup system prompt (see `Cleaner.prewarm`). Reads
    /// the model file ahead (llama-server maps it) while the one-token
    /// request pages in the rest.
    @discardableResult
    public func prewarm(prompt: String?) -> Task<Bool, Never> {
        Task.detached { [weak self] in
            guard let self else { return false }
            async let weights: Void = Prewarm.readAheadInBackground(self.modelPath)
            var answered = false
            if (try? await self.ensureServerRunning(polls: Self.spawnPolls)) != nil {
                answered = await Prewarm.send(try? Self.makePrewarmRequest(system: prompt ?? "", port: self.server.port),
                                              with: self.session)
            }
            await weights
            return answered
        }
    }

    public func shutdown() {
        server.shutdown()
    }

    private func ensureServerRunning(polls: Int) async throws {
        let ready = try await server.ensureRunning(polls: polls) {
            guard LocalServer.isSafeToExecute(binaryPath) else {
                throw LlamaCppError.binaryMissing(binaryPath)
            }
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw LlamaCppError.modelMissing(modelPath)
            }
        }
        guard ready else {
            throw polls < Self.warmUpPolls ? LlamaCppError.serverLoading : LlamaCppError.serverTimeout
        }
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

    /// The system prompt with a placeholder transcript, one output token.
    public static func makePrewarmRequest(system: String, port: Int) throws -> URLRequest {
        try makeChatRequest(system: system, user: "<transcript>\nok\n</transcript>", maxTokens: 1, port: port)
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
