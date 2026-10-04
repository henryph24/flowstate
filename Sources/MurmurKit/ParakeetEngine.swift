import Foundation

public enum ParakeetError: Error, LocalizedError {
    case binaryMissing(String)
    case modelMissing(String)
    case serverTimeout
    case http(status: Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .binaryMissing: return "parakeet-server not installed (run scripts/install_parakeet.sh)"
        case .modelMissing: return "Parakeet model missing (run scripts/install_parakeet.sh)"
        case .serverTimeout: return "Local Parakeet server didn't start"
        case .http(let status): return "Local Parakeet error \(status)"
        case .badResponse: return "Unreadable response from the local Parakeet server"
        }
    }
}

/// Local transcription with NVIDIA Parakeet TDT through parakeet.cpp's
/// `parakeet-server` (OpenAI-style `/v1/audio/transcriptions`), kept warm as a
/// child process. Parakeet decodes greedily and takes no prompt, so vocabulary
/// repair is left to `TranscriptCorrector` and the cleanup pass.
public final class ParakeetEngine: TranscriptionEngine, LocalServerEngine, Prewarmable {
    /// Attention cost grows with the square of the length: on an M3 Pro a
    /// 600 s recording takes 43 s and 3.3 GB in one pass, 7.9 s in 60 s chunks.
    public static let maxChunkSeconds = 60.0

    private let binaryPath: String
    private let modelPath: String
    private let session: URLSession
    private let server: ChildServer

    public init(binaryPath: String, modelPath: String, port: Int,
                session: URLSession = LoopbackURLSession.make(resourceTimeout: 90)) {
        let binary = (binaryPath as NSString).expandingTildeInPath
        let model = (modelPath as NSString).expandingTildeInPath
        self.binaryPath = binary
        self.modelPath = model
        self.session = session
        self.server = ChildServer(name: "parakeet-server", binaryPath: binary, port: port,
                                  session: session) { port in
            Self.serverArguments(modelPath: model, port: port)
        }
    }

    deinit { shutdown() }

    /// `prompt` is ignored: Parakeet has no decoder prompt.
    public func transcribe(wav: Data, prompt: String?) async throws -> String {
        try await ensureServerRunning()
        return try await AudioChunker.transcribe(wav: wav, maxSeconds: Self.maxChunkSeconds) { piece in
            try await ensureServerRunning() // a retry after a crash respawns the server
            let request = Self.makeTranscriptionRequest(wav: piece, port: server.port)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ParakeetError.http(status: status) }
            return try Self.parseResponse(data)
        }
    }

    /// Spawns the server eagerly so the model is warm before the first
    /// utterance. Safe to call repeatedly.
    public func warmUp() {
        Task.detached { [weak self] in try? await self?.ensureServerRunning() }
    }

    /// `prompt` is ignored, as in `transcribe`.
    @discardableResult
    public func prewarm(prompt: String?) -> Task<Bool, Never> {
        Task.detached { [weak self] in
            guard let self, (try? await self.ensureServerRunning()) != nil else { return false }
            return await Prewarm.send(Self.makePrewarmRequest(port: self.server.port), with: self.session)
        }
    }

    public func shutdown() {
        server.shutdown()
    }

    private func ensureServerRunning() async throws {
        let ready = try await server.ensureRunning(polls: 120) {
            guard LocalServer.isSafeToExecute(binaryPath) else {
                throw ParakeetError.binaryMissing(binaryPath)
            }
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw ParakeetError.modelMissing(modelPath)
            }
        }
        guard ready else { throw ParakeetError.serverTimeout }
    }

    // MARK: pure request/argument builders (unit-tested)

    /// The model is always an existing local file: parakeet-server treats any
    /// other `--model` value as a name or URL to download.
    public static func serverArguments(modelPath: String, port: Int) -> [String] {
        ["--model", modelPath,
         "--host", "127.0.0.1",
         "--port", String(port),
         "--threads", String(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))]
    }

    public static func makePrewarmRequest(port: Int) -> URLRequest {
        makeTranscriptionRequest(wav: Prewarm.silence, port: port)
    }

    public static func makeTranscriptionRequest(wav: Data, port: Int) -> URLRequest {
        var multipart = MultipartBody()
        multipart.addField(name: "response_format", value: "json")
        multipart.addFile(name: "file", filename: "audio.wav", contentType: "audio/wav", data: wav)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finalized()
        request.timeoutInterval = 60
        return request
    }

    public static func parseResponse(_ data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ParakeetError.badResponse
        }
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
