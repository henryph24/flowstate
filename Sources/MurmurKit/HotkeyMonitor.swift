import AppKit

/// Watches the push-to-talk key via NSEvent global+local monitors.
/// Requires Accessibility trust only (not Input Monitoring) — verified by
/// spike on this machine and confirmed by Apple DTS (forums thread 707680).
///
/// The physical fn key arrives ONLY as .flagsChanged with keyCode 63; the
/// .function flag also rides along on arrow/Home/End keyDowns, so detection
/// must key off (.flagsChanged, keyCode) — never the flag alone.
public final class HotkeyMonitor {
    public var onHotkeyDown: () -> Void = {}
    public var onHotkeyUp: () -> Void = {}
    public var onOtherKeyDown: () -> Void = {}

    private let keyCode: UInt16
    private let flag: NSEvent.ModifierFlags
    private var monitors: [Any] = []
    private var hotkeyIsDown = false

    public init(hotkey: Hotkey) {
        self.keyCode = hotkey.keyCode
        self.flag = hotkey.flag
    }

    deinit { stop() }

    public func start() {
        guard monitors.isEmpty else { return }
        // Global monitors never see events delivered to our own app, hence the
        // mirroring local monitor (cheap insurance for an LSUIElement app).
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { [weak self] event in self?.handle(event) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { [weak self] event in self?.handle(event); return event }) {
            monitors.append(local)
        }
    }

    public func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        hotkeyIsDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == keyCode else { return }
            let isDown = event.modifierFlags.contains(flag)
            guard isDown != hotkeyIsDown else { return } // dedupe repeats/spurious
            hotkeyIsDown = isDown
            isDown ? onHotkeyDown() : onHotkeyUp()
        case .keyDown:
            onOtherKeyDown()
        default:
            break
        }
    }
}
