import Foundation

/// The warm loopback server process behind a local engine. Reuses a verified
/// orphan of its own binary on the preferred port, otherwise spawns a child
/// (on a private port when a foreign process holds the preferred one), then
/// polls `GET /health` until it answers 200. A spawned child counts as ready
/// only once it (or a process it started) is seen listening on the port:
/// `lsof` cannot see another user's listener when the port is picked, and
/// audio must never reach a squatter that answered in the child's place.
///
/// Callers overlap (warm-up, dictation, an engine switch), so one start runs
/// at a time and the shared state sits behind a lock. A child that fails
/// before it is ready sends the next start to a fresh port. `shutdown()`
/// retires the server (app quit, engine switch): a start under way or begun
/// later leaves nothing running and reports not ready.
public final class ChildServer {
    private let name: String
    private let binaryPath: String
    private let preferredPort: Int
    private let session: URLSession
    private let arguments: (Int) -> [String]
    private let owns: (pid_t, Int) -> Bool
    private let gate = StartGate()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var process: Process?
    private var verified = false
    private var currentPort: Int
    private var avoidPreferredPort = false
    private var retired = false

    /// `arguments` builds the command line for the port the child binds.
    /// `owns` tells whether a pid holds the port (tests replace the lsof check).
    public init(name: String, binaryPath: String, port: Int, session: URLSession,
                owns: @escaping (pid_t, Int) -> Bool = ChildServer.listens(pid:port:),
                arguments: @escaping (Int) -> [String]) {
        self.name = name
        self.binaryPath = binaryPath
        self.preferredPort = port
        self.currentPort = port
        self.session = session
        self.owns = owns
        self.arguments = arguments
    }

    deinit { shutdown() }

    /// The port of the server last started or adopted. A request uses the
    /// port `ensureRunning` returns, because a later start can move this one.
    public var port: Int { locked { currentPort } }

    /// The server's port once it answers `/health`, polling up to `polls`
    /// times (250 ms apart; a probe gives up after 1 s without data). When no
    /// child of ours is running, `preflight` runs first (binary and model
    /// checks), then the server is adopted or spawned. Nil on timeout, as soon
    /// as a spawned child exits (a bad model never becomes ready), when
    /// another process answered on the child's port (the child is stopped),
    /// or once `shutdown()` has run.
    public func ensureRunning(polls: Int, preflight: () throws -> Void) async throws -> Int? {
        if let port = await verifiedHealthyPort() { return port }
        await gate.enter()
        do {
            let ready = try await start(polls: polls, preflight: preflight)
            await gate.leave()
            return ready
        } catch {
            await gate.leave()
            throw error
        }
    }

    /// Stops the child and retires the server for good.
    public func shutdown() {
        let child = locked { () -> Process? in
            defer { process = nil; verified = false; retired = true }
            return process
        }
        child?.terminate()
    }

    public static func healthRequest(port: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 1
        return request
    }

    /// True when `pid`, or a process it started (a wrapper script that does
    /// not `exec`), is listening on the loopback `port`.
    public static func listens(pid: pid_t, port: Int) -> Bool {
        LocalServer.listeningPIDs(port: port).contains {
            $0 == pid || LocalServer.parentPID(of: $0) == pid
        }
    }

    // MARK: internals

    private func start(polls: Int, preflight: () throws -> Void) async throws -> Int? {
        guard !locked({ retired }) else { return nil }
        // A caller ahead of us at the gate may have finished the start.
        if let port = await verifiedHealthyPort() { return port }

        let child: Process? // nil: an adopted orphan, attributed by resolvePort
        let target: Int
        if let running = locked({ process?.isRunning == true ? process : nil }) {
            child = running
            target = port
        } else {
            try preflight()
            let avoid = locked { () -> Bool in
                // A child that exited before it was ready (after its start
                // gave up polling) may have lost the port as well.
                if process != nil && !verified { avoidPreferredPort = true }
                process = nil
                verified = false
                return avoidPreferredPort
            }
            let decision = avoid
                ? .spawn(LocalServer.freeLoopbackPort() ?? preferredPort)
                : LocalServer.resolvePort(preferred: preferredPort, binaryPath: binaryPath)
            switch decision {
            case .adopt(let adopted):
                locked { currentPort = adopted }
                child = nil
                target = adopted
            case .spawn(let free):
                let server = Process()
                server.executableURL = URL(fileURLWithPath: binaryPath)
                server.arguments = arguments(free)
                server.standardOutput = FileHandle.nullDevice
                server.standardError = FileHandle.nullDevice
                server.environment = LocalServer.sanitizedEnvironment()
                try server.run()
                let kept = locked { () -> Bool in
                    guard !retired else { return false }
                    process = server
                    currentPort = free
                    return true
                }
                guard kept else { // retired during this start
                    server.terminate()
                    return nil
                }
                Log.info("\(name) spawned (pid \(server.processIdentifier), port \(free))")
                child = server
                target = free
            }
        }

        for _ in 0..<polls {
            if await isHealthy(port: target) {
                // An adopted orphan is ours unless the server retired meanwhile.
                guard let child else { return locked({ retired }) ? nil : target }
                let holdsPort = child.isRunning && owns(child.processIdentifier, target)
                // Decided under the lock: a shutdown during the probe or the
                // ownership check wins, and then this answer is not the child's.
                let current = locked { () -> Bool in
                    guard process === child else { return false }
                    if holdsPort { verified = true }
                    return true
                }
                guard current else { return nil }
                if holdsPort { return target }
                Log.info("\(name): another process answered on port \(target); refusing it")
                abandon(child)
                return nil
            }
            if let child, !child.isRunning {
                abandon(child)
                return nil
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    /// Drops a child that never became ready and keeps later starts off its
    /// port, which may belong to a process `lsof` cannot see.
    private func abandon(_ child: Process) {
        locked {
            if process === child { process = nil }
            avoidPreferredPort = true
        }
        if child.isRunning { child.terminate() }
    }

    private func verifiedHealthyPort() async -> Int? {
        guard let (child, port) = locked({ () -> (Process, Int)? in
            guard verified, let process, process.isRunning else { return nil }
            return (process, currentPort)
        }) else { return nil }
        guard await isHealthy(port: port) else { return nil }
        // A shutdown or a new child during the probe wins.
        return locked { verified && process === child } ? port : nil
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let (_, response) = try? await session.data(for: Self.healthRequest(port: port))
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Admits one caller at a time, in arrival order.
private actor StartGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
