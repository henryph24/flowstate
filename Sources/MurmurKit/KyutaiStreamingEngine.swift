import Foundation

public enum KyutaiError: Error, LocalizedError {
    case binaryMissing(String)
    case configMissing(String)
    case serverTimeout
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing: return "moshi-server not installed (run scripts/install_kyutai.sh)"
        case .configMissing: return "Kyutai config missing (run scripts/install_kyutai.sh)"
        case .serverTimeout: return "Kyutai server didn't start (first run downloads ~2.4 GB)"
        case .server(let m): return "Kyutai server error: \(m)"
        }
    }
}

/// Local *streaming* STT via Kyutai's `moshi-server` (Rust, Metal), managed as a
/// warm child process exactly like `WhisperCppEngine`. Audio is streamed over a
/// msgpack WebSocket (`/api/asr-streaming`) during the hold and finalized on
/// release, so latency is a fixed ~0.5 s flush rather than scaling with length.
public final class KyutaiStreamingEngine: StreamingTranscriptionEngine, LocalServerEngine {
    private let binaryPath: String
    private let configPath: String
    private let preferredPort: Int
    private var activePort: Int
    private let apiKey: String
    private let session: URLSession
    private var process: Process?

    public init(binaryPath: String, configPath: String, port: Int, apiKey: String,
                session: URLSession = LoopbackURLSession.make(resourceTimeout: 60)) {
        self.binaryPath = (binaryPath as NSString).expandingTildeInPath
        self.configPath = (configPath as NSString).expandingTildeInPath
        self.preferredPort = port
        self.activePort = port
        self.apiKey = apiKey
        self.session = session
    }

    deinit { shutdown() }

    // MARK: StreamingTranscriptionEngine

    public func makeSession() throws -> TranscriptionSession {
        guard LocalServer.isSafeToExecute(binaryPath) else {
            throw KyutaiError.binaryMissing(binaryPath)
        }
        let task = session.webSocketTask(with: Self.webSocketRequest(port: activePort, apiKey: apiKey))
        return KyutaiSession(socket: task)
    }

    /// Spawns the server eagerly so the model is warm (and, on first run,
    /// downloaded) before the first utterance. Safe to call repeatedly.
    public func warmUp() {
        Task.detached { [weak self] in try? await self?.ensureServerRunning() }
    }

    /// Ensures the server is up (spawning + awaiting first-run model load).
    /// Lets a caller fail fast before opening a streaming session.
    public func ensureReady() async throws {
        try await ensureServerRunning()
    }

    public func shutdown() {
        process?.terminate()
        process = nil
    }

    // MARK: server lifecycle (mirrors WhisperCppEngine)

    @discardableResult
    private func ensureServerRunning() async throws -> Bool {
        // Fast path: a child WE spawned this session is already up.
        if let running = process, running.isRunning, await isResponsive() { return true }

        guard LocalServer.isSafeToExecute(binaryPath) else {
            throw KyutaiError.binaryMissing(binaryPath)
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw KyutaiError.configMissing(configPath)
        }

        // Reuse only a verified orphan of our own binary; otherwise spawn on a
        // private port rather than adopting a foreign listener on the fixed port.
        if process == nil || process?.isRunning != true {
            switch LocalServer.resolvePort(preferred: preferredPort, binaryPath: binaryPath) {
            case .adopt(let port):
                activePort = port
            case .spawn(let port):
                activePort = port
                let server = Process()
                server.executableURL = URL(fileURLWithPath: binaryPath)
                server.arguments = Self.serverArguments(configPath: configPath, port: activePort)
                server.standardOutput = FileHandle.nullDevice
                server.standardError = FileHandle.nullDevice
                server.environment = LocalServer.sanitizedEnvironment()
                try server.run()
                process = server
                Log.info("moshi-server spawned (pid \(server.processIdentifier), port \(activePort))")
            }
        }

        // First run downloads ~2.4 GB then loads the model on Metal; allow a long warmup.
        for _ in 0..<1200 {
            if await isResponsive() { return true }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw KyutaiError.serverTimeout
    }

    private func isResponsive() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(activePort)/")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse) != nil
    }

    // MARK: pure builders (unit-tested)

    public static func serverArguments(configPath: String, port: Int) -> [String] {
        // --addr 127.0.0.1: bind loopback only. moshi-server defaults to 0.0.0.0
        // (all interfaces), which on shared/public Wi-Fi would expose the STT
        // endpoint to the whole LAN.
        ["worker", "--config", configPath, "--addr", "127.0.0.1", "--port", String(port)]
    }

    public static func webSocketRequest(port: Int, apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/api/asr-streaming")!)
        request.setValue(apiKey, forHTTPHeaderField: "kyutai-api-key")
        return request
    }

    /// `{"type":"Audio","pcm":[f32…]}` — the per-frame audio message.
    public static func audioMessage(_ pcm: [Float]) -> Data {
        var w = MsgPackWriter()
        w.writeMapHeader(2)
        w.writeString("type"); w.writeString("Audio")
        w.writeString("pcm"); w.writeFloat32Array(pcm)
        return w.data
    }

    /// `{"type":"Marker","id":id}` — the end-of-stream flush sentinel.
    public static func markerMessage(id: Int) -> Data {
        var w = MsgPackWriter()
        w.writeMapHeader(2)
        w.writeString("type"); w.writeString("Marker")
        w.writeString("id"); w.writeInt(id)
        return w.data
    }

    public enum OutMsg {
        case ready
        case word(text: String, startTime: Double)
        case endWord(stopTime: Double)
        case step(prs: [Float])
        case marker(id: Int)
        case error(String)
        case unknown(String)
    }

    public static func parse(_ data: Data) -> OutMsg {
        guard let value = try? MsgPackValue.decode(data),
              let type = value["type"]?.stringValue else {
            return .unknown("undecodable")
        }
        switch type {
        case "Ready":   return .ready
        case "Word":    return .word(text: value["text"]?.stringValue ?? "",
                                     startTime: value["start_time"]?.doubleValue ?? 0)
        case "EndWord": return .endWord(stopTime: value["stop_time"]?.doubleValue ?? 0)
        case "Step":    return .step(prs: value["prs"]?.floatArrayValue ?? [])
        case "Marker":  return .marker(id: value["id"]?.intValue ?? 0)
        case "Error":   return .error(value["message"]?.stringValue ?? "unknown")
        default:        return .unknown(type)
        }
    }
}

/// One push-to-talk utterance over the Kyutai WebSocket. Audio is queued through
/// an `AsyncStream` (so `append` never blocks the audio thread); a send Task
/// drains it, a receive Task decodes words. `finish()` flushes with a `Marker`
/// and trailing silence, then returns the assembled transcript.
final class KyutaiSession: TranscriptionSession {
    var onPartial: ((String) -> Void)?

    private let socket: URLSessionWebSocketTask
    private let audioStream: AsyncStream<[Float]>
    private let audioContinuation: AsyncStream<[Float]>.Continuation

    private let lock = NSLock()
    private var words: [String] = []
    private var markerDone = false
    private var failure: Error?

    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    /// 1 s of leading silence primes the model and avoids clipping the first word.
    private static let leadingSilence = [Float](repeating: 0, count: 24_000)
    /// 80 ms zero-frame used to flush after the marker.
    private static let silenceFrame = [Float](repeating: 0, count: 1_920)

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
        var continuation: AsyncStream<[Float]>.Continuation!
        self.audioStream = AsyncStream { continuation = $0 }   // closure runs synchronously
        self.audioContinuation = continuation
        socket.resume()
        startReceiveLoop()
        startSendLoop()
    }

    // MARK: TranscriptionSession

    func append(_ pcm: [Float]) {
        audioContinuation.yield(pcm)
    }

    func finish() async throws -> String {
        audioContinuation.finish()          // end the mic stream
        await sendTask?.value               // leading silence + all mic audio sent

        // Flush the model's delay window: ~1 s of trailing silence so the final
        // words are committed, then the marker, then keep feeding silence until
        // the server echoes the marker back. The receive loop keeps draining
        // *past* the marker, and we wait a short grace after the echo — the 1b
        // model can emit the last word in the same step as the marker, so
        // stopping on the marker alone clips it.
        for _ in 0..<12 {
            try? await socket.send(.data(KyutaiStreamingEngine.audioMessage(Self.silenceFrame)))
        }
        try? await socket.send(.data(KyutaiStreamingEngine.markerMessage(id: 0)))

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if isMarkerDone() {
                try? await Task.sleep(nanoseconds: 250_000_000)  // grace for a same-step final word
                break
            }
            try? await socket.send(.data(KyutaiStreamingEngine.audioMessage(Self.silenceFrame)))
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        receiveTask?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)

        if let failure = currentFailure() { throw failure }
        return assembledTranscript()
    }

    func cancel() {
        audioContinuation.finish()
        sendTask?.cancel()
        receiveTask?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    // MARK: loops

    private func startSendLoop() {
        sendTask = Task { [weak self] in
            guard let self else { return }
            try? await self.socket.send(.data(KyutaiStreamingEngine.audioMessage(Self.leadingSilence)))
            for await chunk in self.audioStream {
                try? await self.socket.send(.data(KyutaiStreamingEngine.audioMessage(chunk)))
            }
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await self.socket.receive()
                } catch {
                    // A clean finish() cancels the socket, which surfaces here as
                    // an error — don't treat that as a transcription failure.
                    if !self.isMarkerDone() { self.setFailure(error) }
                    return
                }
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                switch KyutaiStreamingEngine.parse(data) {
                case .word(let text, _):
                    self.appendWord(text)
                case .marker:
                    self.setMarkerDone()   // keep draining — a final word can arrive just after
                case .error(let message):
                    self.setFailure(KyutaiError.server(message))
                    return
                case .ready, .endWord, .step, .unknown:
                    continue
                }
            }
        }
    }

    // MARK: shared state (lock-guarded)

    private func appendWord(_ text: String) {
        let joined: String
        lock.lock()
        words.append(text)
        joined = words.joined(separator: " ")
        lock.unlock()
        if let onPartial {
            DispatchQueue.main.async { onPartial(joined) }
        }
    }

    private func setMarkerDone() { lock.lock(); markerDone = true; lock.unlock() }
    private func isMarkerDone() -> Bool { lock.lock(); defer { lock.unlock() }; return markerDone }
    private func setFailure(_ error: Error) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
    private func currentFailure() -> Error? { lock.lock(); defer { lock.unlock() }; return failure }
    private func assembledTranscript() -> String {
        lock.lock(); defer { lock.unlock() }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
