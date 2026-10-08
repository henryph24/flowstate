import AppKit

/// Small "home" window for the app — gives the Dock icon something to open
/// (clicking a Dock icon with no window feels broken). Mirrors the menu bar
/// actions for users who prefer a window: a header, a status row, and a
/// settings grid.
public final class StatusWindowController: NSWindowController {
    public var onSetAPIKey: () -> Void = {}
    public var onSelectEngine: (EngineKind) -> Void = { _ in }
    public var onToggleCleanup: () -> Void = {}
    public var onStartAtLogin: () -> Void = {}
    public var onQuit: () -> Void = {}

    /// Everything the window shows that can change at runtime.
    public struct State {
        public var hotkey: String
        public var engine: EngineKind
        /// Nil when the engine is ready; otherwise what the user must fix.
        public var problem: String?
        public var cleanupEnabled: Bool
        public var launchAtLogin: Bool

        public init(hotkey: String, engine: EngineKind, problem: String?,
                    cleanupEnabled: Bool, launchAtLogin: Bool) {
            self.hotkey = hotkey
            self.engine = engine
            self.problem = problem
            self.cleanupEnabled = cleanupEnabled
            self.launchAtLogin = launchAtLogin
        }
    }

    private let statusDot = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let keyCap = NSTextField(labelWithString: "")
    private var keyCapWidth: NSLayoutConstraint?
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cleanupSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Flowstate"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func update(_ state: State) {
        keyCap.stringValue = state.hotkey
        keyCapWidth?.constant = ceil(keyCap.cell?.cellSize.width ?? 40) + 20
        if let problem = state.problem {
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = problem
        } else {
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = "Ready. Hold the key anywhere, speak, release to paste."
        }
        if enginePopup.numberOfItems == EngineKind.allCases.count,
           let index = EngineKind.allCases.firstIndex(of: state.engine) {
            enginePopup.selectItem(at: index)
        }
        cleanupSwitch.state = state.cleanupEnabled ? .on : .off
        loginSwitch.state = state.launchAtLogin ? .on : .off
    }

    // MARK: - layout

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let header = buildHeader()
        let status = buildStatusRow()
        let settings = buildSettings()
        let footer = buildFooter()

        let stack = NSStackView(views: [header, status, settings, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(20, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settings.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func buildHeader() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "Flowstate")
        title.font = .systemFont(ofSize: 24, weight: .bold)

        let tagline = NSTextField(labelWithString: "Hold a key, speak, release. Your words land where the cursor is.")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, tagline])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        return header
    }

    private func buildStatusRow() -> NSView {
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        keyCap.font = .systemFont(ofSize: 12, weight: .semibold)
        keyCap.alignment = .center
        keyCap.lineBreakMode = .byClipping
        keyCap.wantsLayer = true
        keyCap.layer?.cornerRadius = 6
        keyCap.layer?.borderWidth = 1
        keyCap.layer?.borderColor = NSColor.separatorColor.cgColor
        keyCap.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        keyCap.translatesAutoresizingMaskIntoConstraints = false
        keyCap.heightAnchor.constraint(equalToConstant: 24).isActive = true
        keyCapWidth = keyCap.widthAnchor.constraint(equalToConstant: 56)
        keyCapWidth?.isActive = true
        keyCap.setContentHuggingPriority(.required, for: .horizontal)
        keyCap.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [statusDot, statusLabel, keyCap])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return Self.card(around: row)
    }

    private func buildSettings() -> NSView {
        enginePopup.removeAllItems()
        for kind in EngineKind.allCases { enginePopup.addItem(withTitle: kind.displayName) }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)

        cleanupSwitch.target = self
        cleanupSwitch.action = #selector(cleanupToggled)
        loginSwitch.target = self
        loginSwitch.action = #selector(loginToggled)

        let keyButton = NSButton(title: "Set…", target: self, action: #selector(setKey))
        keyButton.bezelStyle = .rounded
        keyButton.controlSize = .small

        let grid = NSGridView(views: [
            [Self.rowLabel("Engine"), enginePopup],
            [Self.rowLabel("AI cleanup"), cleanupSwitch],
            [Self.rowLabel("Start at login"), loginSwitch],
            [Self.rowLabel("Groq API key"), keyButton],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        grid.cell(for: enginePopup)?.xPlacement = .fill
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .center }

        let section = NSStackView(views: [Self.sectionTitle("Settings"), grid])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        grid.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func buildFooter() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionLabel = NSTextField(labelWithString: version.map { "Version \($0)" } ?? "")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor

        let quit = NSButton(title: "Quit Flowstate", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]

        let row = NSStackView(views: [versionLabel, NSView(), quit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.views[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [separator, row])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 12
        separator.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        return footer
    }

    private static func card(around view: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    private static func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - actions

    @objc private func setKey() { onSetAPIKey() }
    @objc private func engineChanged() {
        let index = enginePopup.indexOfSelectedItem
        guard EngineKind.allCases.indices.contains(index) else { return }
        onSelectEngine(EngineKind.allCases[index])
    }
    @objc private func cleanupToggled() { onToggleCleanup() }
    @objc private func loginToggled() { onStartAtLogin() }
    @objc private func quit() { onQuit() }
}
