import Foundation

/// Scrolling bar heights behind the HUD waveform: the newest input level
/// enters at the right, older levels slide left. Pure (testable); the HUD
/// turns `heights` into layer frames.
public struct WaveformBars {
    /// Height (0...1) a bar shows for silence, so the meter never looks dead.
    public static let idleHeight: CGFloat = 0.18

    public private(set) var heights: [CGFloat]

    public init(count: Int) {
        heights = Array(repeating: Self.idleHeight, count: max(1, count))
    }

    public mutating func push(level: Float) {
        let clamped = CGFloat(max(0, min(1, level)))
        heights.removeFirst()
        heights.append(max(Self.idleHeight, clamped))
    }

    public mutating func reset() {
        heights = Array(repeating: Self.idleHeight, count: heights.count)
    }
}
