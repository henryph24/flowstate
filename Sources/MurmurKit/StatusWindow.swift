import AppKit

/// Small "home" window for the app — gives the Dock icon something to open
/// (clicking a Dock icon with no window feels broken). Mirrors the menu bar
/// actions for users who prefer a window.
public final class StatusWindowController: NSWindowController {
    public var onSetAPIKey: () -> Void = {}
    public var onSelectEngine: (EngineKind) -> Void = { _ in }
    public var onStartAtLogin: () -> Void = {}
    public var onQuit: () -> Void = {}

    private let statusLabel = NSTextField(labelWithString: "")
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Flowstate"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func update(statusText: String, selectedEngine: EngineKind) {
        statusLabel.stringValue = statusText
        if enginePopup.numberOfItems == EngineKind.allCases.count,
           let index = EngineKind.allCases.firstIndex(of: selectedEngine) {
            enginePopup.selectItem(at: index)
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = NSTextField(labelWithString: "Flowstate")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center

        let hint = NSTextField(labelWithString: "Hold your dictation key anywhere, speak, release.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let keyButton = NSButton(title: "Set Groq API Key…", target: self, action: #selector(setKey))
        enginePopup.removeAllItems()
        for kind in EngineKind.allCases { enginePopup.addItem(withTitle: kind.displayName) }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        let loginButton = NSButton(title: "Start at Login", target: self, action: #selector(startAtLogin))
        let quitButton = NSButton(title: "Quit Flowstate", target: self, action: #selector(quit))
        for button in [keyButton, loginButton, quitButton] {
            button.bezelStyle = .rounded
        }

        let buttons = NSStackView(views: [keyButton, enginePopup, loginButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [icon, title, hint, statusLabel, buttons, quitButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func setKey() { onSetAPIKey() }
    @objc private func engineChanged() {
        let index = enginePopup.indexOfSelectedItem
        guard EngineKind.allCases.indices.contains(index) else { return }
        onSelectEngine(EngineKind.allCases[index])
    }
    @objc private func startAtLogin() { onStartAtLogin() }
    @objc private func quit() { onQuit() }
}
