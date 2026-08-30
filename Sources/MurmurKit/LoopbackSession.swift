import Foundation
import Darwin

/// Refuses every HTTP redirect. The inference servers live on loopback and Groq
/// never 3xx-redirects these endpoints, so a redirect can only come from a
/// hostile/compromised responder trying to bounce our microphone audio (or the
/// transcript) to another host — deny it at the session layer.
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectSessionDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The URLSession every engine uses. Ephemeral (nothing is written to the
/// on-disk URL cache, so dictation transcripts never persist to
/// ~/Library/Caches), cache-disabled even in memory, redirect-refusing, and
/// bounded by a resource timeout so a hostile server cannot stream forever.
public enum LoopbackURLSession {
    public static func make(resourceTimeout: TimeInterval = 60) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: cfg,
                          delegate: NoRedirectSessionDelegate.shared,
                          delegateQueue: nil)
    }

    /// One-time cleanup of the legacy on-disk transcript cache written by earlier
    /// versions that used `URLSession.shared`. Empties the app's `URLCache`.
    public static func purgeLegacyCache() {
        URLCache.shared.removeAllCachedResponses()
    }
}

/// Helpers for launching and safely re-using the local inference child servers.
/// The security property this enforces: the app only ever sends audio to, and
/// accepts transcripts from, a server it spawned itself or one it has verified
/// (by executable path) is a genuine orphan of its own configured binary — never
/// a foreign process squatting the port.
public enum LocalServer {
    /// What to do with the preferred port: adopt a verified own-binary orphan
    /// already listening there, or spawn our own child (on that port if free,
    /// otherwise on a private ephemeral port a squatter can't predict).
    public enum PortDecision: Equatable {
        case adopt(Int)
        case spawn(Int)
    }

    public static func resolvePort(preferred: Int, binaryPath: String) -> PortDecision {
        let listeners = listeningPIDs(port: preferred)
        if listeners.isEmpty { return .spawn(preferred) }
        let target = resolvedPath(binaryPath)
        let ours = listeners.contains { pid in
            guard let path = executablePath(pid: pid) else { return false }
            return resolvedPath(path) == target
        }
        if ours { return .adopt(preferred) }
        Log.info("port \(preferred) held by another process — using a private port instead")
        return .spawn(freeLoopbackPort() ?? preferred)
    }

    /// Asks the OS for an unused loopback TCP port (bind :0, read it, close).
    public static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// PIDs listening on a loopback TCP port (via `lsof`).
    public static func listeningPIDs(port: Int) -> [pid_t] {
        guard let out = runTool("/usr/sbin/lsof",
                                ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) else { return [] }
        return out.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap { pid_t($0) }
    }

    /// The on-disk executable path of a running process (via `proc_pidpath`).
    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Child servers inherit the app's environment MINUS anything credential-
    /// shaped (a large third-party binary should never receive GROQ_API_KEY etc.).
    /// HOME/PATH/DYLD/HF_* are preserved so the servers still find their runtime
    /// and model caches.
    public static func sanitizedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where isSensitiveEnvKey(key) { env.removeValue(forKey: key) }
        return env
    }

    public static func isSensitiveEnvKey(_ key: String) -> Bool {
        let k = key.uppercased()
        return k.hasSuffix("_API_KEY") || k.hasSuffix("_APIKEY") || k.hasSuffix("_SECRET")
            || k.hasSuffix("_TOKEN") || k.hasSuffix("_PASSWORD") || k.hasSuffix("_PASSWD")
            || k.contains("SECRET") || k == "GROQ_API_KEY"
    }

    /// Refuses to launch a world-writable binary — on a shared Mac, any other
    /// user could overwrite it, and this process holds Accessibility.
    public static func isSafeToExecute(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return true }
        return (perms & 0o002) == 0
    }

    // MARK: internals

    private static func resolvedPath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    private static func runTool(_ launchPath: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.environment = sanitizedEnvironment()
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
