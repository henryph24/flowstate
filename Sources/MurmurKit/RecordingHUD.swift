import AppKit

/// Floating feedback pill at the bottom-center of the screen. Never takes
/// focus (nonactivating panel ordered front without becoming key).
public final class RecordingHUD {
    public enum HUDState {
        case listening
        case processing
        case done
        case error(String)
        case copiedSecureInput
        case busy
    }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(label)
        panel.contentView = effect
    }

    public func show(_ state: HUDState) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        apply(state)
        panel.orderFrontRegardless()
    }

    public func flash(_ state: HUDState, for duration: TimeInterval = 1.2) {
        show(state)
        let item = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    public func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.orderOut(nil)
    }

    /// Renders the streaming transcript live while listening (Kyutai); falls
    /// back to the plain "Listening…" pill when the text is still empty.
    public func updateLiveText(_ text: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apply(.listening)
        } else {
            render(symbol: "●", text: trimmed, symbolColor: .systemRed)
        }
        panel.orderFrontRegardless()
    }

    private func apply(_ state: HUDState) {
        let (symbol, text, color): (String, String, NSColor)
        switch state {
        case .listening:          (symbol, text, color) = ("●", "Listening…", .systemRed)
        case .processing:         (symbol, text, color) = ("●", "Transcribing…", .systemOrange)
        case .done:               (symbol, text, color) = ("✓", "Inserted", .systemGreen)
        case .error(let message): (symbol, text, color) = ("✕", message, .systemRed)
        case .copiedSecureInput:  (symbol, text, color) = ("⧉", "Copied — press ⌘V (secure input)", .systemYellow)
        case .busy:               (symbol, text, color) = ("●", "Still working…", .systemOrange)
        }
        render(symbol: symbol, text: text, symbolColor: color)
    }

    private func render(symbol: String, text: String, symbolColor: NSColor) {
        let font = label.font ?? .systemFont(ofSize: 13, weight: .medium)
        let attributed = NSMutableAttributedString(
            string: symbol + "  ", attributes: [.foregroundColor: symbolColor, .font: font])
        attributed.append(NSAttributedString(
            string: text, attributes: [.foregroundColor: NSColor.labelColor, .font: font]))
        label.attributedStringValue = attributed

        let textSize = attributed.size()
        let width = min(textSize.width + 36, 520)
        let height: CGFloat = 36
        panel.setContentSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: 18, y: (height - textSize.height) / 2,
                             width: width - 36, height: textSize.height)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 60))
        }
    }
}
