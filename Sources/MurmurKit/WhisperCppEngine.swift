import Foundation

public enum WhisperCppError: Error, LocalizedError {
    case binaryMissing(String)
    case modelMissing(String)
    case serverTimeout
    case http(status: Int)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing: return "whisper-server not installed (brew install whisper-cpp)"
        case .modelMissing: return "Whisper model file missing"
        case .serverTimeout: return "Local Whisper server didn't start"
        case .http(let status): return "Local Whisper error \(status)"
        }
    }
}

/// Local transcription via whisper.cpp's `whisper-server`, managed as a child
/// process so the model loads once and stays warm between utterances.
/// If a server is already answering on the port (e.g. orphaned by a crash),
/// it is reused instead of spawning a duplicate.
public final class WhisperCppEngine: TranscriptionEngine, LocalServerEngine {
    private let binaryPath: String
    private let modelPath: String
    private let preferredPort: Int
    private var activePort: Int
    private let language: String
    private let session: URLSession
    private var process: Process?

    public init(binaryPath: String, modelPath: String, port: Int,
                language: String = "en",
                session: URLSession = LoopbackURLSession.make(resourceTimeout: 90)) {
        self.binaryPath = binaryPath
        self.modelPath = (modelPath as NSString).expandingTildeInPath
        self.preferredPort = port
        self.activePort = port
        self.language = language
        self.session = session
    }

    deinit { shutdown() }

    public func transcribe(wav: Data, prompt: String?) async throws -> String {
        try await ensureServerRunning()
        let request = Self.makeInferenceRequest(wav: wav, port: activePort, prompt: prompt)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WhisperCppError.http(status: status) }
        struct Response: Decodable { let text: String }
        let text = try JSONDecoder().decode(Response.self, from: data).text
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spawns the server eagerly so the model is warm before the first
    /// utterance. Safe to call repeatedly.
    public func warmUp() {
        Task.detached { [weak self] in try? await self?.ensureServerRunning() }
    }

    public func shutdown() {
        process?.terminate()
        process = nil
    }

    // MARK: server lifecycle

    private func ensureServerRunning() async throws {
        // Fast path: a child WE spawned this session is already up.
        if let running = process, running.isRunning, await isResponsive() { return }

        guard LocalServer.isSafeToExecute(binaryPath) else {
            throw WhisperCppError.binaryMissing(binaryPath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperCppError.modelMissing(modelPath)
        }

        // Never adopt a listener we can't attribute to our own binary — a squatter
        // on the fixed port would otherwise receive the mic audio and return text
        // we'd paste. Reuse only a verified orphan of our binary; otherwise spawn
        // on a private port a squatter can't predict.
        if process == nil || process?.isRunning != true {
            switch LocalServer.resolvePort(preferred: preferredPort, binaryPath: binaryPath) {
            case .adopt(let port):
                activePort = port
            case .spawn(let port):
                activePort = port
                let server = Process()
                server.executableURL = URL(fileURLWithPath: binaryPath)
                server.arguments = Self.serverArguments(modelPath: modelPath, port: activePort,
                                                        language: language)
                server.standardOutput = FileHandle.nullDevice
                server.standardError = FileHandle.nullDevice
                server.environment = LocalServer.sanitizedEnvironment()
                try server.run()
                process = server
                Log.info("whisper-server spawned (pid \(server.processIdentifier), port \(activePort))")
            }
        }

        // Model load takes a few seconds; poll until the HTTP server answers.
        for _ in 0..<120 {
            if await isResponsive() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw WhisperCppError.serverTimeout
    }

    private func isResponsive() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(activePort)/")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse) != nil
    }

    // MARK: pure request/argument builders (unit-tested)

    public static func serverArguments(modelPath: String, port: Int,
                                       language: String) -> [String] {
        // Accuracy-tuned defaults: pin the language (no auto-detect misfires on
        // the first words), beam search at width 5 (OpenAI-parity decoding —
        // whisper.cpp ships greedy), suppress non-speech tokens so bracketed
        // noise markers don't leak into dictated text, and re-apply the prompt to
        // every 30s window (`--carry-initial-prompt`) so vocabulary biasing holds
        // through long dictations, not just the first segment.
        ["-m", modelPath,
         "--host", "127.0.0.1",
         "--port", String(port),
         "-l", language,
         "-bs", "5",
         "-bo", "5",
         "-sns",
         "--carry-initial-prompt",
         "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))]
    }

    public static func makeInferenceRequest(wav: Data, port: Int,
                                            prompt: String? = nil) -> URLRequest {
        var multipart = MultipartBody()
        multipart.addField(name: "temperature", value: "0")
        multipart.addField(name: "response_format", value: "json")
        if let prompt, !prompt.isEmpty {
            multipart.addField(name: "prompt", value: prompt)
        }
        multipart.addFile(name: "file", filename: "audio.wav", contentType: "audio/wav", data: wav)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finalized()
        request.timeoutInterval = 60
        return request
    }
}
