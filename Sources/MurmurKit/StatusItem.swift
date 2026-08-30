import AppKit

/// Menu bar icon + menu. Pure UI shell — all behavior is injected as closures.
public final class StatusItemController: NSObject {
    public enum IconState {
        case idle, recording, processing, needsSetup
    }

    public var onSetAPIKey: () -> Void = {}
    public var onSelectEngine: (EngineKind) -> Void = { _ in }
    public var onToggleCleanup: () -> Void = {}
    public var onToggleDockIcon: () -> Void = {}
    public var onShowWindow: () -> Void = {}
    public var onToggleLaunchAtLogin: () -> Void = {}
    public var onQuit: () -> Void = {}

    private let statusItem: NSStatusItem
    private let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var engineItems: [EngineKind: NSMenuItem] = [:]
    private let cleanupItem: NSMenuItem
    private let dockItem: NSMenuItem
    private let launchItem: NSMenuItem

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        cleanupItem = NSMenuItem(title: "AI Cleanup", action: #selector(toggleCleanup(_:)), keyEquivalent: "")
        dockItem = NSMenuItem(title: "Show Dock Icon", action: #selector(toggleDockIcon(_:)), keyEquivalent: "")
        launchItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        super.init()

        let menu = NSMenu()
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        let windowItem = NSMenuItem(title: "Open Flowstate Window", action: #selector(showWindow(_:)), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)
        menu.addItem(.separator())

        let keyItem = NSMenuItem(title: "Set API Key…", action: #selector(setAPIKey(_:)), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)

        let engineMenu = NSMenu()
        for kind in EngineKind.allCases {
            let item = NSMenuItem(title: kind.displayName,
                                  action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            engineMenu.addItem(item)
            engineItems[kind] = item
        }
        let engineParent = NSMenuItem(title: "Transcription Engine", action: nil, keyEquivalent: "")
        engineParent.submenu = engineMenu
        menu.addItem(engineParent)

        cleanupItem.target = self
        menu.addItem(cleanupItem)

        dockItem.target = self
        menu.addItem(dockItem)

        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Flowstate", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        setIcon(.idle)
    }

    public func setIcon(_ state: IconState) {
        let (symbol, description): (String, String)
        switch state {
        case .idle:       (symbol, description) = ("mic", "Flowstate idle")
        case .recording:  (symbol, description) = ("mic.fill", "Flowstate recording")
        case .processing: (symbol, description) = ("ellipsis.circle", "Flowstate transcribing")
        case .needsSetup: (symbol, description) = ("mic.slash", "Flowstate needs setup")
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: description)
    }

    public func setInfo(_ text: String) {
        infoItem.title = text
    }

    public func setSelectedEngine(_ kind: EngineKind) {
        for (itemKind, item) in engineItems {
            item.state = itemKind == kind ? .on : .off
        }
    }

    public func setCleanupChecked(_ checked: Bool) {
        cleanupItem.state = checked ? .on : .off
    }

    public func setDockIconChecked(_ checked: Bool) {
        dockItem.state = checked ? .on : .off
    }

    public func setLaunchAtLoginChecked(_ checked: Bool) {
        launchItem.state = checked ? .on : .off
    }

    @objc private func setAPIKey(_ sender: Any?) { onSetAPIKey() }
    @objc private func selectEngine(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let kind = EngineKind(rawValue: raw) {
            onSelectEngine(kind)
        }
    }
    @objc private func toggleCleanup(_ sender: Any?) { onToggleCleanup() }
    @objc private func toggleDockIcon(_ sender: Any?) { onToggleDockIcon() }
    @objc private func showWindow(_ sender: Any?) { onShowWindow() }
    @objc private func toggleLaunchAtLogin(_ sender: Any?) { onToggleLaunchAtLogin() }
    @objc private func quit(_ sender: Any?) { onQuit() }
}
