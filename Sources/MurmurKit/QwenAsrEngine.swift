import Foundation

public enum QwenAsrError: Error, LocalizedError {
    case binaryMissing(String)
    case modelMissing(String)
    case serverTimeout
    case http(status: Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .binaryMissing: return "llama-server not installed (run scripts/install_qwen_asr.sh)"
        case .modelMissing: return "Qwen3-ASR model missing (run scripts/install_qwen_asr.sh)"
        case .serverTimeout: return "Local Qwen3-ASR server didn't start"
        case .http(let status): return "Local Qwen3-ASR error \(status)"
        case .badResponse: return "Unreadable response from the local Qwen3-ASR server"
        }
    }
}

/// Local transcription with Qwen3-ASR served by llama.cpp's `llama-server`
/// and its audio projector (`--mmproj`), kept warm as a child process beside
/// the cleanup server. The vocabulary prompt goes in as the system message,
/// which Qwen3-ASR reads as spelling context, and the assistant turn is
/// prefilled with the language tag so the model skips language detection.
public final class QwenAsrEngine: TranscriptionEngine, LocalServerEngine, Prewarmable {
    /// 60 s is about 750 audio tokens: with the vocabulary prompt and the
    /// output it stays far inside `-c 4096`.
    public static let maxChunkSeconds = 60.0

    private let binaryPath: String
    private let modelPath: String
    private let mmprojPath: String
    private let language: String
    private let session: URLSession
    private let server: ChildServer

    public init(binaryPath: String, modelPath: String, mmprojPath: String, port: Int,
                language: String = "en",
                session: URLSession = LoopbackURLSession.make(resourceTimeout: 90)) {
        let model = (modelPath as NSString).expandingTildeInPath
        let mmproj = (mmprojPath as NSString).expandingTildeInPath
        self.binaryPath = binaryPath
        self.modelPath = model
        self.mmprojPath = mmproj
        self.language = language
        self.session = session
        self.server = ChildServer(name: "llama-server (Qwen3-ASR)", binaryPath: binaryPath,
                                  port: port, session: session) { port in
            Self.serverArguments(modelPath: model, mmprojPath: mmproj, port: port)
        }
    }

    deinit { shutdown() }

    public func transcribe(wav: Data, prompt: String?) async throws -> String {
        try await ensureServerRunning()
        return try await AudioChunker.transcribe(wav: wav, maxSeconds: Self.maxChunkSeconds) { piece in
            try await ensureServerRunning() // a retry after a crash respawns the server
            let request = try Self.makeTranscriptionRequest(wav: piece, prompt: prompt,
                                                            language: language, port: server.port)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw QwenAsrError.http(status: status) }
            return try Self.parseResponse(data)
        }
    }

    /// Spawns the server eagerly so the model is warm before the first
    /// utterance. Safe to call repeatedly.
    public func warmUp() {
        Task.detached { [weak self] in try? await self?.ensureServerRunning() }
    }

    /// Reads the model file ahead (llama-server maps it; the projector is
    /// loaded into memory) while the one-token request pages in the rest.
    @discardableResult
    public func prewarm(prompt: String?) -> Task<Bool, Never> {
        Task.detached { [weak self] in
            guard let self else { return false }
            async let weights: Void = Prewarm.readAheadInBackground(self.modelPath)
            var answered = false
            if (try? await self.ensureServerRunning()) != nil {
                answered = await Prewarm.send(try? Self.makePrewarmRequest(prompt: prompt, language: self.language,
                                                                           port: self.server.port),
                                              with: self.session)
            }
            await weights
            return answered
        }
    }

    public func shutdown() {
        server.shutdown()
    }

    private func ensureServerRunning() async throws {
        let ready = try await server.ensureRunning(polls: 120) {
            guard LocalServer.isSafeToExecute(binaryPath) else {
                throw QwenAsrError.binaryMissing(binaryPath)
            }
            for path in [modelPath, mmprojPath] where !FileManager.default.fileExists(atPath: path) {
                throw QwenAsrError.modelMissing(path)
            }
        }
        guard ready else { throw QwenAsrError.serverTimeout }
    }

    // MARK: pure request/argument builders (unit-tested)

    /// Same minimal flag set as `LlamaCppChatEngine` plus the projector.
    public static func serverArguments(modelPath: String, mmprojPath: String, port: Int) -> [String] {
        ["-m", modelPath,
         "--mmproj", mmprojPath,
         "--host", "127.0.0.1",
         "--port", String(port),
         "-c", "4096",
         "-ngl", "99",
         "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))]
    }

    /// The silent clip with the prompt and prefill of a real request, one output token.
    public static func makePrewarmRequest(prompt: String?, language: String, port: Int) throws -> URLRequest {
        try makeTranscriptionRequest(wav: Prewarm.silence, prompt: prompt, language: language, port: port,
                                     tokenLimit: 1)
    }

    /// `tokenLimit` nil: the output cap scales with the audio (`maxTokens(forWAVBytes:)`).
    public static func makeTranscriptionRequest(wav: Data, prompt: String?, language: String,
                                                port: Int, tokenLimit: Int? = nil) throws -> URLRequest {
        var messages: [[String: Any]] = []
        if let prompt, !prompt.isEmpty {
            messages.append(["role": "system", "content": prompt])
        }
        messages.append(["role": "user", "content": [[
            "type": "input_audio",
            "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
        ]]])
        if let name = languageName(for: language) {
            // llama-server continues a trailing assistant message.
            messages.append(["role": "assistant", "content": "language \(name)<asr_text>"])
        }
        let body: [String: Any] = [
            "messages": messages,
            "temperature": 0,
            "max_tokens": tokenLimit ?? maxTokens(forWAVBytes: wav.count),
            "cache_prompt": true,
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        return request
    }

    /// Output cap: 8 tokens per second of audio (fast speech runs about 6)
    /// plus 64. A repetition loop stops at the cap.
    public static func maxTokens(forWAVBytes bytes: Int) -> Int {
        let seconds = Double(max(0, bytes - 44)) / 32_000
        return Int(seconds * 8) + 64
    }

    /// Qwen3-ASR's name for an ISO 639 code; nil lets the model detect.
    public static func languageName(for code: String) -> String? {
        languageNames[code.lowercased()]
    }

    private static let languageNames: [String: String] = [
        "en": "English", "zh": "Chinese", "yue": "Cantonese", "ar": "Arabic", "de": "German",
        "fr": "French", "es": "Spanish", "pt": "Portuguese", "id": "Indonesian", "it": "Italian",
        "ko": "Korean", "ru": "Russian", "th": "Thai", "vi": "Vietnamese", "ja": "Japanese",
        "tr": "Turkish", "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech", "fil": "Filipino",
        "fa": "Persian", "el": "Greek", "hu": "Hungarian", "mk": "Macedonian", "ro": "Romanian",
    ]

    /// The text after `<asr_text>` (the reply echoes the prefilled tag).
    public static func parseResponse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let content = response.choices.first?.message.content else {
            throw QwenAsrError.badResponse
        }
        var text = Substring(content)
        if let tag = text.range(of: "<asr_text>") { text = text[tag.upperBound...] }
        if let close = text.range(of: "</asr_text>") { text = text[..<close.lowerBound] }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
