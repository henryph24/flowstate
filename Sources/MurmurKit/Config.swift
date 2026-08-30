import AppKit

public enum Hotkey: String, Codable {
    case fn
    case rightCommand

    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63           // kVK_Function
        case .rightCommand: return 54 // kVK_RightCommand
        }
    }

    public var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightCommand: return .command
        }
    }

    public var displayName: String {
        switch self {
        case .fn: return "fn"
        case .rightCommand: return "right ⌘"
        }
    }
}

public enum EngineKind: String, Codable, CaseIterable {
    case groq
    case whisperCpp
    case kyutai

    /// Shown in the engine picker (menu bar submenu + status window).
    public var displayName: String {
        switch self {
        case .groq: return "Groq (cloud)"
        case .whisperCpp: return "Local Whisper (whisper.cpp)"
        case .kyutai: return "Local Kyutai (streaming)"
        }
    }

    public var isLocal: Bool {
        switch self {
        case .groq: return false
        case .whisperCpp, .kyutai: return true
        }
    }
}

/// Which backend runs the cleanup LLM pass. STT engine choice is separate
/// (`EngineKind`) — cleanup is Groq- or llama.cpp-backed regardless of STT.
public enum CleanupEngineKind: String, Codable, CaseIterable {
    case local
    case groq

    public var displayName: String {
        switch self {
        case .local: return "Local (llama.cpp)"
        case .groq: return "Groq (cloud)"
        }
    }

    public var isLocal: Bool { self == .local }
}

public struct Config {
    public var groqAPIKey: String?
    public var language = "en"
    public var engine: EngineKind = .whisperCpp
    public var sttModel = "whisper-large-v3-turbo"
    public var cleanupModel = "llama-3.1-8b-instant"
    public var cleanupEnabled = true
    /// local → llama.cpp child server (run scripts/install_llama.sh once);
    /// groq → cloud chat (needs an API key). Default is local-first.
    public var cleanupEngine: CleanupEngineKind = .local
    public var llamaBinaryPath = "/opt/homebrew/bin/llama-server"
    public var llamaModelPath = "~/Library/Application Support/Murmur/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    public var llamaPort = 8725
    /// General vocabulary biased into the Whisper prompt in every app, and into
    /// the cleanup LLM's spelling guide. Empty = no biasing.
    public var customVocabulary: [String] = []
    /// Software-engineering vocabulary added (ahead of `customVocabulary`) only
    /// when the frontmost app is a code editor / IDE / terminal.
    public var codeVocabulary: [String] = []
    /// Appends the shipped SWE/AI/ML list (`BuiltinVocabulary.terms`) after the
    /// user's terms — user terms win the prompt budget and the casing. Off =
    /// user vocabulary only, like before the list existed.
    public var builtinVocabularyEnabled = true
    /// Extra spoken-form → replacement fixes for the deterministic corrector
    /// ("pie torch": "PyTorch" style). Applied ahead of the builtin aliases.
    public var vocabularyAliases: [String: String] = [:]
    /// Watches the field Murmur just pasted into (Accessibility, same-app
    /// only, one read, short window) and promotes a corrected term into
    /// `customVocabulary`/`codeVocabulary` after it recurs twice. Only the
    /// learned term is ever stored — never field contents. false disables
    /// entirely (autolearn.json is then never touched).
    public var autoLearnEnabled = true
    public var showDockIcon = false
    public var whisperBinaryPath = "/opt/homebrew/bin/whisper-server"
    public var whisperModelPath = "~/Library/Application Support/Murmur/models/ggml-large-v3-turbo.bin"
    public var whisperPort = 8723
    public var kyutaiBinaryPath = "~/.cargo/bin/moshi-server"
    public var kyutaiConfigPath: String?   // nil → app-managed default in Application Support
    public var kyutaiPort = 8090
    public var kyutaiApiKey = "public_token"
    public var hotkey: Hotkey = .fn
    public var minHoldSeconds: TimeInterval = 0.25
    public var maxRecordSeconds: TimeInterval = 600
    public var pasteboardRestoreDelay: TimeInterval = 0.6
    /// True when config.json exists but failed to parse. We then run on defaults
    /// but refuse to `save()` over it, so a hand-edited file isn't destroyed (and
    /// a deliberately-set kill switch like autoLearnEnabled:false isn't silently
    /// reverted) by the next menu toggle.
    public var loadFailedUnparseable = false

    public enum ConfigError: Error { case refusingToOverwriteUnparseable }

    public init() {}

    /// Ordered term list to bias for a given app context. User terms come
    /// first so they win the capped prompt budget and — via `normalize`'s
    /// first-seen dedup — their casing. Code apps then get the built-in SWE
    /// list ahead of the built-in general list; every other app gets the
    /// built-in general list (econ/finance/stats/research).
    public func vocabulary(for context: AppContext) -> [String] {
        switch context {
        case .code:
            let user = codeVocabulary + customVocabulary
            guard builtinVocabularyEnabled else { return user }
            return user + BuiltinVocabulary.code + BuiltinVocabulary.general
        case .general:
            guard builtinVocabularyEnabled else { return customVocabulary }
            return customVocabulary + BuiltinVocabulary.general
        }
    }

    /// Context-independent union handed to the cleanup LLM's spelling rule
    /// (capped there) and the `TranscriptCorrector` index (uncapped), built
    /// once per engine rebuild. User terms first so their casing wins
    /// `normalize`'s first-seen rule.
    public var cleanupVocabulary: [String] {
        let user = customVocabulary + codeVocabulary
        return builtinVocabularyEnabled ? user + BuiltinVocabulary.cleanupPriority : user
    }

    /// Spoken-form aliases for the corrector: user entries first (sorted for
    /// determinism — dictionary order isn't stable) so they win key collisions,
    /// then the builtin list unless builtin vocabulary is disabled.
    public var effectiveAliases: [(spoken: String, replacement: String)] {
        let user = vocabularyAliases.sorted { $0.key < $1.key }
            .map { (spoken: $0.key, replacement: $0.value) }
        return builtinVocabularyEnabled ? user + BuiltinVocabulary.spokenAliases : user
    }

    // MARK: persistence — ~/.config/murmur/config.json, every key optional

    private struct FileConfig: Codable {
        var groqAPIKey: String?
        var language: String?
        var engine: EngineKind?
        var sttModel: String?
        var cleanupModel: String?
        var cleanupEnabled: Bool?
        var cleanupEngine: CleanupEngineKind?
        var llamaBinaryPath: String?
        var llamaModelPath: String?
        var llamaPort: Int?
        var customVocabulary: [String]?
        var codeVocabulary: [String]?
        var builtinVocabularyEnabled: Bool?
        var vocabularyAliases: [String: String]?
        var autoLearnEnabled: Bool?
        var showDockIcon: Bool?
        var whisperBinaryPath: String?
        var whisperModelPath: String?
        var whisperPort: Int?
        var kyutaiBinaryPath: String?
        var kyutaiConfigPath: String?
        var kyutaiPort: Int?
        var kyutaiApiKey: String?
        var hotkey: Hotkey?
        var minHoldSeconds: TimeInterval?
        var maxRecordSeconds: TimeInterval?
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/murmur/config.json")
    }

    /// Env var wins for the API key (dev loops); file fills in the rest.
    public static func load() -> Config {
        var config = Config()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let file = try JSONDecoder().decode(FileConfig.self, from: data)
                config.apply(file)
            } catch {
                // Malformed JSON or a type mismatch: run on defaults but never
                // overwrite the user's file (see loadFailedUnparseable).
                Log.info("config.json is unparseable (\(error.localizedDescription)); "
                    + "using defaults and refusing to overwrite it")
                config.loadFailedUnparseable = true
            }
        }
        if let envKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !envKey.isEmpty {
            config.groqAPIKey = envKey
        }
        if let envHotkey = ProcessInfo.processInfo.environment["MURMUR_HOTKEY"],
           let hotkey = Hotkey(rawValue: envHotkey) {
            config.hotkey = hotkey
        }
        if let envEngine = ProcessInfo.processInfo.environment["MURMUR_ENGINE"],
           let engine = EngineKind(rawValue: envEngine) {
            config.engine = engine
        }
        if let envCleanup = ProcessInfo.processInfo.environment["MURMUR_CLEANUP_ENGINE"],
           let cleanup = CleanupEngineKind(rawValue: envCleanup) {
            config.cleanupEngine = cleanup
        }
        return config
    }

    private mutating func apply(_ file: FileConfig) {
        groqAPIKey = file.groqAPIKey ?? groqAPIKey
        language = file.language ?? language
        engine = file.engine ?? engine
        sttModel = file.sttModel ?? sttModel
        cleanupModel = file.cleanupModel ?? cleanupModel
        cleanupEnabled = file.cleanupEnabled ?? cleanupEnabled
        cleanupEngine = file.cleanupEngine ?? cleanupEngine
        llamaBinaryPath = file.llamaBinaryPath ?? llamaBinaryPath
        llamaModelPath = file.llamaModelPath ?? llamaModelPath
        llamaPort = file.llamaPort ?? llamaPort
        customVocabulary = file.customVocabulary ?? customVocabulary
        codeVocabulary = file.codeVocabulary ?? codeVocabulary
        builtinVocabularyEnabled = file.builtinVocabularyEnabled ?? builtinVocabularyEnabled
        vocabularyAliases = file.vocabularyAliases ?? vocabularyAliases
        autoLearnEnabled = file.autoLearnEnabled ?? autoLearnEnabled
        showDockIcon = file.showDockIcon ?? showDockIcon
        whisperBinaryPath = file.whisperBinaryPath ?? whisperBinaryPath
        whisperModelPath = file.whisperModelPath ?? whisperModelPath
        whisperPort = file.whisperPort ?? whisperPort
        kyutaiBinaryPath = file.kyutaiBinaryPath ?? kyutaiBinaryPath
        kyutaiConfigPath = file.kyutaiConfigPath ?? kyutaiConfigPath
        kyutaiPort = file.kyutaiPort ?? kyutaiPort
        kyutaiApiKey = file.kyutaiApiKey ?? kyutaiApiKey
        hotkey = file.hotkey ?? hotkey
        minHoldSeconds = file.minHoldSeconds ?? minHoldSeconds
        maxRecordSeconds = file.maxRecordSeconds ?? maxRecordSeconds
    }

    public func save() throws {
        guard !loadFailedUnparseable else { throw ConfigError.refusingToOverwriteUnparseable }
        let file = FileConfig(
            groqAPIKey: groqAPIKey,
            language: language,
            engine: engine,
            sttModel: sttModel,
            cleanupModel: cleanupModel,
            cleanupEnabled: cleanupEnabled,
            cleanupEngine: cleanupEngine,
            llamaBinaryPath: llamaBinaryPath,
            llamaModelPath: llamaModelPath,
            llamaPort: llamaPort,
            customVocabulary: customVocabulary,
            codeVocabulary: codeVocabulary,
            builtinVocabularyEnabled: builtinVocabularyEnabled,
            vocabularyAliases: vocabularyAliases,
            autoLearnEnabled: autoLearnEnabled,
            showDockIcon: showDockIcon,
            whisperBinaryPath: whisperBinaryPath,
            whisperModelPath: whisperModelPath,
            whisperPort: whisperPort,
            kyutaiBinaryPath: kyutaiBinaryPath,
            kyutaiConfigPath: kyutaiConfigPath,
            kyutaiPort: kyutaiPort,
            kyutaiApiKey: kyutaiApiKey,
            hotkey: hotkey,
            minHoldSeconds: minHoldSeconds,
            maxRecordSeconds: maxRecordSeconds
        )
        let dir = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an already-existing dir's mode untouched; an
        // install created before the 0700 default kept 0755, so repair it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        // Restrict the creation mode around the write so a first-ever save never
        // lands world-readable (0644) with the API key in it before we chmod —
        // Foundation preserves perms only when overwriting an existing file.
        let previousUmask = umask(0o077)
        // Atomic: auto-learn writes from a background timer; a torn write must
        // never corrupt hand-edited config.
        try data.write(to: Self.fileURL, options: .atomic)
        umask(previousUmask)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }
}
