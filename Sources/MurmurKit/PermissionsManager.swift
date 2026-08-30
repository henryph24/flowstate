import AVFoundation
import ApplicationServices

public enum PermissionsManager {
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func accessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        guard promptIfNeeded else { return AXIsProcessTrusted() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// System Settings → Keyboard → "Press 🌐 key to". 0 = Do Nothing.
    /// Returns nil when the preference was never set (can't infer the default).
    public static func fnKeySystemActionIsDoNothing() -> Bool? {
        guard let value = CFPreferencesCopyValue("AppleFnUsageType" as CFString,
                                                 "com.apple.HIToolbox" as CFString,
                                                 kCFPreferencesCurrentUser,
                                                 kCFPreferencesAnyHost) else { return nil }
        return (value as? NSNumber)?.intValue == 0
    }
}
