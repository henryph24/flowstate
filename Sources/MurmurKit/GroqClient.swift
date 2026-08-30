import Foundation

public enum GroqError: Error, LocalizedError {
    case http(status: Int, body: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .http(401, _): return "Invalid API key"
        case .http(413, _): return "Audio too large"
        case .http(429, _): return "Rate limited — try again"
        case .http(let status, _): return "Groq error \(status)"
        case .emptyResponse: return "Empty response from Groq"
        }
    }
}

public final class GroqClient: TranscriptionEngine, ChatEngine {
    private let apiKey: String
    private let sttModel: String
    private let chatModel: String
    private let language: String
    private let session: URLSession

    private static let transcriptionsURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private static let chatURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    public init(apiKey: String, sttModel: String, chatModel: String, language: String,
                session: URLSession = LoopbackURLSession.make(resourceTimeout: 60)) {
        self.apiKey = apiKey
        self.sttModel = sttModel
        self.chatModel = chatModel
        self.language = language
        self.session = session
    }

    public func transcribe(wav: Data, prompt: String?) async throws -> String {
        var multipart = MultipartBody()
        multipart.addField(name: "model", value: sttModel)
        multipart.addField(name: "language", value: language)
        multipart.addField(name: "temperature", value: "0")
        multipart.addField(name: "response_format", value: "json")
        if let prompt, !prompt.isEmpty {
            multipart.addField(name: "prompt", value: prompt)
        }
        multipart.addFile(name: "file", filename: "audio.wav", contentType: "audio/wav", data: wav)

        var request = URLRequest(url: Self.transcriptionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finalized()
        request.timeoutInterval = 30

        struct Response: Decodable { let text: String }
        let data = try await sendWithOneRetryOnTimeout(request)
        let text = try JSONDecoder().decode(Response.self, from: data).text
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func chatComplete(system: String, user: String, maxTokens: Int) async throws -> String {
        struct Message: Codable { let role: String; let content: String }
        struct Body: Codable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let max_completion_tokens: Int
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }

        var request = URLRequest(url: Self.chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(
            model: chatModel,
            messages: [Message(role: "system", content: system),
                       Message(role: "user", content: user)],
            temperature: 0,
            max_completion_tokens: maxTokens
        ))
        request.timeoutInterval = 10

        let data = try await send(request)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let content = response.choices.first?.message.content else {
            throw GroqError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GroqError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func sendWithOneRetryOnTimeout(_ request: URLRequest) async throws -> Data {
        do {
            return try await send(request)
        } catch let error as URLError where error.code == .timedOut {
            return try await send(request)
        }
    }
}
