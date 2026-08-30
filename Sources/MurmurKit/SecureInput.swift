import Carbon

/// True while a process holds secure keyboard entry (password fields,
/// Terminal's Secure Keyboard Entry, etc.) — synthetic ⌘V won't land there.
public func isSecureInputActive() -> Bool {
    IsSecureEventInputEnabled()
}
