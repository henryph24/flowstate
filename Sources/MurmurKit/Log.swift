import Foundation

/// Timestamped stdout logging — visible in `swift run` dev loops and when
/// launching the bundled binary from a shell; inert under Finder launches.
public enum Log {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static func info(_ message: String) {
        print("[\(formatter.string(from: Date()))] \(message)")
    }
}
