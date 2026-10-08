import AppKit

/// Floating feedback capsule at the bottom-center of the screen. Never takes
/// focus (nonactivating panel ordered front without becoming key). Shows a
/// live waveform while listening, a spinner while transcribing, and a glyph
/// for the outcome. Fades in and out; width follows the text.
public final class RecordingHUD {
    public enum HUDState {
        case listening
        case processing
        case done
        case error(String)
        case copiedSecureInput
        case busy
    }

    private static let height: CGFloat = 44
    private static let barCount = 7
    private static let glyphWidth: CGFloat = 26
    private static let padding: CGFloat = 16
    private static let gap: CGFloat = 10
    private static let maxWidth: CGFloat = 560
    private static let bottomInset: CGFloat = 56

    private let panel: NSPanel
    private let container: NSVisualEffectView
    private let label = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let waveform = NSView()
    private var barLayers: [CALayer] = []
    private var bars = WaveformBars(count: RecordingHUD.barCount)
    private var hideWorkItem: DispatchWorkItem?
    private var isListening = false

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.alphaValue = 0

        container = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.height / 2
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // The vibrancy backdrop ignores the layer's corner radius; the mask
        // image is what clips it (and the window shadow) to the capsule.
        container.maskImage = Self.capsuleMask(height: Self.height)
        container.autoresizingMask = [.width, .height]

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .vibrantDark)

        waveform.wantsLayer = true
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemRed.cgColor
            bar.cornerRadius = 1.5
            waveform.layer?.addSublayer(bar)
            barLayers.append(bar)
        }

        let tint = NSView(frame: container.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        tint.autoresizingMask = [.width, .height]
        container.addSubview(tint)
        for view in [waveform, spinner, glyph, label] { container.addSubview(view) }
        panel.contentView = container
    }

    public func show(_ state: HUDState) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        apply(state)
        fadeIn()
    }

    public func flash(_ state: HUDState, for duration: TimeInterval = 1.2) {
        show(state)
        let item = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    public func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fadeOut()
    }

    /// Feeds one input level (0...1, see `AudioRecorder.meterLevel`) into the
    /// waveform. Ignored unless the HUD is in the listening state.
    public func pushLevel(_ level: Float) {
        guard isListening else { return }
        bars.push(level: level)
        layoutBars(animated: true)
    }

    /// Renders the streaming transcript live while listening (Kyutai); falls
    /// back to the plain "Listening" capsule when the text is still empty.
    public func updateLiveText(_ text: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apply(.listening)
        } else {
            render(leading: .waveform, text: trimmed, textColor: .white)
        }
        fadeIn()
    }

    // MARK: - rendering

    private enum Leading {
        case waveform
        case spinner
        case symbol(String, NSColor)
    }

    private func apply(_ state: HUDState) {
        switch state {
        case .listening:
            render(leading: .waveform, text: "Listening", textColor: .white)
        case .processing:
            render(leading: .spinner, text: "Transcribing", textColor: .white)
        case .busy:
            render(leading: .spinner, text: "Still working", textColor: .white)
        case .done:
            render(leading: .symbol("checkmark.circle.fill", .systemGreen), text: "Inserted", textColor: .white)
        case .error(let message):
            render(leading: .symbol("exclamationmark.triangle.fill", .systemRed), text: message, textColor: .white)
        case .copiedSecureInput:
            render(leading: .symbol("doc.on.clipboard.fill", .systemYellow),
                   text: "Copied. Press ⌘V to paste (secure input)", textColor: .white)
        }
    }

    private func render(leading: Leading, text: String, textColor: NSColor) {
        let wasListening = isListening
        isListening = false
        waveform.isHidden = true
        glyph.isHidden = true
        spinner.stopAnimation(nil)
        switch leading {
        case .waveform:
            isListening = true
            waveform.isHidden = false
            if !wasListening {
                bars.reset()
                layoutBars(animated: false)
            }
        case .spinner:
            spinner.startAnimation(nil)
        case .symbol(let name, let color):
            glyph.isHidden = false
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: text)
            glyph.contentTintColor = color
        }

        label.stringValue = text
        label.textColor = textColor
        // cellSize includes the field's own horizontal inset; intrinsicContentSize does not.
        let textWidth = min(ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width) + 2,
                            Self.maxWidth - Self.padding * 2 - Self.glyphWidth - Self.gap)
        let width = Self.padding + Self.glyphWidth + Self.gap + textWidth + Self.padding
        let height = Self.height

        let leadingFrame = NSRect(x: Self.padding, y: (height - Self.glyphWidth) / 2,
                                  width: Self.glyphWidth, height: Self.glyphWidth)
        waveform.frame = leadingFrame
        glyph.frame = leadingFrame
        spinner.frame = leadingFrame.insetBy(dx: 5, dy: 5)
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: leadingFrame.maxX + Self.gap, y: (height - textHeight) / 2,
                             width: textWidth, height: textHeight)

        var origin = panel.frame.origin
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            origin = NSPoint(x: (visible.midX - width / 2).rounded(), y: visible.minY + Self.bottomInset)
        }
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        if panel.alphaValue > 0, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
        if case .waveform = leading { layoutBars(animated: false) }
    }

    private func layoutBars(animated: Bool) {
        let area = waveform.bounds
        let count = CGFloat(barLayers.count)
        let barWidth: CGFloat = 2.5
        let spacing = (area.width - barWidth * count) / (count - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.08) }
        for (index, bar) in barLayers.enumerated() {
            let barHeight = max(3, area.height * bars.heights[index])
            bar.frame = CGRect(x: CGFloat(index) * (barWidth + spacing),
                               y: (area.height - barHeight) / 2,
                               width: barWidth, height: barHeight)
        }
        CATransaction.commit()
    }

    private static func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let size = NSSize(width: height + 1, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - visibility

    private func fadeIn() {
        guard !(panel.isVisible && panel.alphaValue == 1) else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        isListening = false
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        })
    }
}
