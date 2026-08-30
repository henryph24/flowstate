import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController(config: Config.load())
        self.controller = controller
        controller.start()
        controller.bootstrapPermissions()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown() // stop the whisper-server child, if any
    }

    /// Dock icon clicked (or app reopened) with no visible windows.
    public func applicationShouldHandleReopen(_ sender: NSApplication,
                                              hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { controller?.handleReopen() }
        return true
    }
}
