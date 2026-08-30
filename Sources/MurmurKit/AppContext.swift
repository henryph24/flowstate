import Foundation

/// Classifies the frontmost app at dictation time so the pipeline can pick
/// context-appropriate vocabulary biasing: code editors / IDEs / terminals get
/// the software-engineering term set, everything else gets the general set.
/// Pure (testable); the impure `NSWorkspace.frontmostApplication` lookup lives
/// in `AppController`.
public enum AppContext: String {
    case code
    case general

    /// Stable bundle IDs of code editors, IDEs, and terminals.
    static let codeBundleIDs: Set<String> = [
        // Editors / IDEs
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.apple.dt.Xcode", "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3",
        "com.panic.Nova", "com.barebones.bbedit", "com.macromates.TextMate",
        "com.google.android.studio",
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable", "co.zeit.hyper", "org.tabby",
    ]

    /// Bundle-ID prefixes — JetBrains ships every IDE under one namespace
    /// (IntelliJ, PyCharm, GoLand, CLion, WebStorm, Rider, DataGrip, …).
    static let codeBundlePrefixes: [String] = ["com.jetbrains."]

    /// App names for editors whose bundle IDs are unstable/shared (todesktop /
    /// Electron wrappers), where matching the ID would misclassify unrelated
    /// apps. Matched exactly against the localized app name.
    static let codeAppNames: Set<String> = ["Cursor", "Windsurf", "Trae"]

    public static func classify(bundleID: String?, appName: String?) -> AppContext {
        if let id = bundleID {
            if codeBundleIDs.contains(id) { return .code }
            if codeBundlePrefixes.contains(where: { id.hasPrefix($0) }) { return .code }
        }
        if let name = appName, codeAppNames.contains(name) { return .code }
        return .general
    }
}
