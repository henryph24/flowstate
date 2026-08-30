import ApplicationServices

/// Reads the focused text of ONE process — the pid Murmur just pasted into —
/// via the Accessibility API. Never system-wide, never persisted; nil on any
/// failure (Electron/web views commonly refuse — that's a silent no-learn).
/// Needs only the AX trust the app already holds for its hotkey monitors.
public enum FieldReader {
    /// AXUIElementCopyAttributeValue is a synchronous IPC round trip; bound it
    /// so an unresponsive target can never stall the main thread.
    public static let messagingTimeout: Float = 0.25

    /// The focused element of `pid` right now, boxed as `AnyObject` so callers
    /// (AutoLearn) can hold it for a later same-field comparison without
    /// importing the Accessibility API. Captured at paste time.
    public static func focusedElement(pid: pid_t) -> AnyObject? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    /// Reads the focused field of `pid` — but ONLY if focus is still on the same
    /// element we captured at paste time (`captured`), and never a secure/password
    /// field. Focus having moved to another field (a search box, a DM draft)
    /// returns nil, so we never mine an unrelated field the user has since clicked.
    public static func focusedText(pid: pid_t, matching captured: AnyObject?) -> String? {
        guard let current = focusedElement(pid: pid) else { return nil }
        if let captured, !CFEqual(current, captured) { return nil }
        let element = unsafeDowncast(current, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == kAXSecureTextFieldSubrole as String {
            return nil // password field — never read it back
        }

        for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
               let text = valueRef as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
