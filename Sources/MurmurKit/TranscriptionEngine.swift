import Foundation

/// Umbrella for anything `AppController` can hold as the active STT engine,
/// whether batch (`TranscriptionEngine`) or streaming
/// (`StreamingTranscriptionEngine`). Lets the controller keep one `engine`
/// slot and branch on capability with `as?`.
public protocol TranscriptionProviding: AnyObject {}

/// Batch STT seam: a complete WAV in, transcript out. Groq today, whisper.cpp.
/// `prompt` is optional decoder biasing (the context-selected vocabulary).
public protocol TranscriptionEngine: TranscriptionProviding {
    func transcribe(wav: Data, prompt: String?) async throws -> String
}

public extension TranscriptionEngine {
    /// Convenience for callers (and tests) that don't bias the decoder.
    func transcribe(wav: Data) async throws -> String {
        try await transcribe(wav: wav, prompt: nil)
    }
}

/// Streaming STT seam (Kyutai): audio is fed incrementally *during* the hold and
/// finalized on release, so latency is a fixed flush rather than scaling with
/// utterance length.
public protocol StreamingTranscriptionEngine: TranscriptionProviding {
    func makeSession() throws -> TranscriptionSession
}

/// One push-to-talk utterance's worth of streaming transcription.
public protocol TranscriptionSession: AnyObject {
    /// Invoked on the main thread with the transcript-so-far as words arrive.
    var onPartial: ((String) -> Void)? { get set }
    /// Feed mic audio (24 kHz mono Float32). Called from the audio thread — must
    /// not block (enqueue and return).
    func append(_ pcm: [Float])
    /// Flush the model and return the final transcript. Called once, on release.
    func finish() async throws -> String
    /// Discard the in-flight stream without finalizing (too-short tap / abort).
    func cancel()
}

/// Engines that own a child server process and must be torn down on app quit.
public protocol LocalServerEngine: AnyObject {
    func shutdown()
}

/// Seam for the cleanup LLM, mockable in tests.
public protocol ChatEngine {
    func chatComplete(system: String, user: String, maxTokens: Int) async throws -> String
}
