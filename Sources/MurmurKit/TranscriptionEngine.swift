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

/// A local model server whose memory macOS takes back while it idles on a Mac
/// short of memory: llama-server's mapped model file drops out of the page
/// cache, and the rest is compressed or swapped. The next request waits while
/// the weights come back: after 10 GB of other file reads, a 5 s dictation on
/// Qwen3-ASR 1.7B and the 3B cleanup model took 5.8 to 6.2 s (0.6 to 0.8 s
/// warm, M3 Pro, 36 GB). Started at key-down, the same page-in runs while the
/// user speaks: 0.9 to 1.1 s after a 3 s hold, 1.1 to 1.8 s after a 1 s hold.
public protocol Prewarmable: AnyObject {
    /// Sends one minimal request through the same server checks as a real
    /// one, so the model pages in while the user is still speaking. `prompt`
    /// is the one the next real request carries (vocabulary or cleanup
    /// system prompt), so the server caches its prefix. The task answers
    /// whether the server replied 200; the app ignores it.
    @discardableResult
    func prewarm(prompt: String?) -> Task<Bool, Never>
}

public enum Prewarm {
    /// One second of 16 kHz silence: every layer of an audio model runs on it,
    /// and a resident model handles it in tens of milliseconds.
    public static let silence = WAVEncoder.encode(samples: [Int16](repeating: 0, count: 16_000),
                                                  sampleRate: 16_000)

    /// Key-down: warms what the coming dictation calls, the batch STT engine
    /// with the dictation's vocabulary prompt and the local cleanup model.
    /// Streaming and cloud engines have nothing to warm. whisper-server is
    /// left out: it encodes a full 30 s window for any request and serves one
    /// request at a time, so on a warm server a prewarm delayed a 0.25 s
    /// dictation by 0.4 s.
    @discardableResult
    public static func forDictation(engine: TranscriptionProviding?, cleaner: Cleaner?,
                                    prompt: String?) -> [Task<Bool, Never>] {
        var tasks: [Task<Bool, Never>] = []
        if let local = engine as? Prewarmable { tasks.append(local.prewarm(prompt: prompt)) }
        if let cleanup = cleaner?.prewarm() { tasks.append(cleanup) }
        return tasks
    }

    /// Reads the parts of the file missing from the page cache with plain
    /// reads, and returns once they are in. Blocks: call it off the main
    /// thread. Under memory pressure fcntl F_RDADVISE left 69-87% of a 1.6 GB
    /// model resident and lost more within seconds; plain reads took the same
    /// 0.4 s and kept all of it. False when the file cannot be opened, mapped
    /// or read.
    @discardableResult
    public static func readAhead(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        let size = Int(info.st_size)
        guard size > 0 else { return true }
        // mincore finds the resident pages: 10 ms for a warm 2 GB model,
        // against 165 ms to read it again.
        guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { return false }
        defer { munmap(map, size) }
        let page = Int(getpagesize())
        var resident = [CChar](repeating: 0, count: (size + page - 1) / page)
        guard mincore(map, size, &resident) == 0 else { return false }
        let window = 4 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: window, alignment: page)
        defer { buffer.deallocate() }
        var first = 0
        while first < resident.count {
            let last = min(first + window / page, resident.count)
            if resident[first..<last].contains(where: { $0 & 1 == 0 }) {
                let offset = first * page
                let length = min(window, size - offset)
                var done = 0
                while done < length {
                    let n = pread(fd, buffer, length - done, off_t(offset + done))
                    if n > 0 {
                        done += n
                    } else if n == 0 {
                        break // the file shrank
                    } else if errno != EINTR {
                        return false
                    }
                }
            }
            first = last
        }
        return true
    }

    /// `readAhead` on a GCD thread, so the blocking read never holds one of
    /// Swift concurrency's few threads.
    static func readAheadInBackground(_ path: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                readAhead(path)
                done.resume()
            }
        }
    }

    /// True when the request got a 200; false on any error.
    static func send(_ request: URLRequest?, with session: URLSession) async -> Bool {
        guard let request, let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// Seam for the cleanup LLM, mockable in tests.
public protocol ChatEngine {
    func chatComplete(system: String, user: String, maxTokens: Int) async throws -> String
}
