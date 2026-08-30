import AppKit
import ServiceManagement

/// Owns the push-to-talk state machine and the per-utterance pipeline:
/// record → WAV → Groq STT → LLM cleanup → paste. Everything here runs on
/// the main thread (NSEvent monitors, timers, and @MainActor tasks); only
/// AudioRecorder's tap touches another thread.
public final class AppController {
    private var config: Config
    private var machine: FnStateMachine
    private let recorder = AudioRecorder()
    private let hud = RecordingHUD()
    private let statusItem = StatusItemController()
    private let statusWindow = StatusWindowController()
    private let monitor: HotkeyMonitor
    private let inserter: TextInserter

    private var engine: TranscriptionProviding? // nil until configured (key or local model)
    private var engineHint: String?          // user-facing reason when engine is nil
    private var cleaner: Cleaner?            // llama.cpp- or Groq-backed; nil when unavailable
    private var chatServer: LocalServerEngine? // local cleanup LLM child, if any
    private var cleanupHint: String?         // why cleanup is off (log only — never blocks recording)
    private var corrector = TranscriptCorrector(terms: []) // deterministic vocab repair, always on
    private var pipelineTask: Task<Void, Never>?
    private var streamSession: TranscriptionSession? // active streaming utterance (Kyutai)
    private var maxDurationTimer: Timer?
    private var dictationContext: AppContext = .general // frontmost-app class at record start
    private var dictationPID: pid_t? // frontmost app at record start (auto-learn read-back target)
    private let autoLearn: AutoLearn

    /// Ceiling on transcript length before it reaches the pasteboard/keystroke
    /// path (~30k words — well above any real dictation, guards a hostile server).
    private static let maxTranscriptChars = 200_000

    public init(config: Config) {
        self.config = config
        self.machine = FnStateMachine(minHold: config.minHoldSeconds)
        self.monitor = HotkeyMonitor(hotkey: config.hotkey)
        self.inserter = TextInserter(restoreDelay: config.pasteboardRestoreDelay)
        self.autoLearn = AutoLearn(
            enabled: config.autoLearnEnabled,
            isKnownWord: SystemDictionary.isKnownWord,
            captureElement: { FieldReader.focusedElement(pid: $0) },
            readField: { FieldReader.focusedText(pid: $0, matching: $1) },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            loadStore: { AutoLearnStoreFile.load() },
            saveStore: { try? AutoLearnStoreFile.save($0) })
    }

    public func start() {
        // Drop any plaintext transcripts a prior version cached to disk via
        // URLSession.shared (engines now use cache-free ephemeral sessions).
        LoopbackURLSession.purgeLegacyCache()
        rebuildEngine()
        autoLearn.existingVocabularyKeys = { [weak self] in
            CorrectionMiner.vocabularyKeys(self?.config.cleanupVocabulary ?? [])
        }
        autoLearn.onLearn = { [weak self] change in self?.applyLearnedTerm(change) }

        monitor.onHotkeyDown = { [weak self] in self?.dispatch(.hotkeyDown(at: Date())) }
        monitor.onHotkeyUp = { [weak self] in self?.dispatch(.hotkeyUp(at: Date())) }
        monitor.onOtherKeyDown = { [weak self] in
            // Pre-filter: keyDown fires for every keystroke system-wide; it only
            // matters as a chord-cancel while recording.
            guard let self, case .recording = self.machine.state else { return }
            self.dispatch(.otherKeyDown)
        }
        recorder.onConfigurationChange = { [weak self] in
            DispatchQueue.main.async { self?.dispatch(.abort) }
        }

        statusItem.onSetAPIKey = { [weak self] in self?.promptForAPIKey() }
        statusItem.onSelectEngine = { [weak self] kind in self?.selectEngine(kind) }
        statusItem.onToggleCleanup = { [weak self] in self?.toggleCleanup() }
        statusItem.onToggleDockIcon = { [weak self] in self?.toggleDockIcon() }
        statusItem.onShowWindow = { [weak self] in self?.showWindow() }
        statusItem.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        statusItem.onQuit = { NSApp.terminate(nil) }

        statusWindow.onSetAPIKey = { [weak self] in self?.promptForAPIKey() }
        statusWindow.onSelectEngine = { [weak self] kind in self?.selectEngine(kind) }
        statusWindow.onStartAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        statusWindow.onQuit = { NSApp.terminate(nil) }

        applyActivationPolicy()
        monitor.start()
        refreshMenu()
        updateIcon()
        let sttDesc: String
        switch config.engine {
        case .groq: sttDesc = "groq/\(config.sttModel)"
        case .whisperCpp: sttDesc = "local whisper.cpp"
        case .kyutai: sttDesc = "local kyutai (streaming)"
        }
        let cleanupDesc: String
        if config.cleanupEnabled, cleaner != nil {
            cleanupDesc = config.cleanupEngine == .local
                ? "local llama.cpp (\(URL(fileURLWithPath: config.llamaModelPath).lastPathComponent))"
                : "groq/\(config.cleanupModel)"
        } else {
            cleanupDesc = "off (\(cleanupHint ?? "unavailable"))"
        }
        Log.info("Flowstate started — hotkey: hold \(config.hotkey.displayName), "
            + "stt: \(sttDesc), cleanup: \(cleanupDesc), "
            + "api key: \(config.groqAPIKey == nil ? "missing" : "present"), "
            + "vocab: \(config.customVocabulary.count + config.codeVocabulary.count) user + "
            + "\(config.builtinVocabularyEnabled ? BuiltinVocabulary.all.count : 0) builtin, "
            + "auto-learn: \(config.autoLearnEnabled ? "on" : "off")")
    }

    public func bootstrapPermissions() {
        if !PermissionsManager.accessibilityTrusted(promptIfNeeded: true) {
            // Monitors installed before trust never start delivering — re-arm
            // them once the user flips the checkbox, instead of requiring a
            // relaunch.
            Log.info("waiting for Accessibility grant…")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard PermissionsManager.accessibilityTrusted(promptIfNeeded: false) else { return }
                timer.invalidate()
                guard let self else { return }
                self.monitor.stop()
                self.monitor.start()
                Log.info("Accessibility granted — hotkey monitors re-armed")
            }
        }
        Task { _ = await PermissionsManager.requestMicrophoneAccess() }
        if config.hotkey == .fn, PermissionsManager.fnKeySystemActionIsDoNothing() == false {
            warnAboutFnSetting()
        }
        if config.engine == .groq, config.groqAPIKey == nil {
            promptForAPIKey()
        }
    }

    /// Tears down child processes (whisper/moshi/llama servers) — call on app
    /// termination.
    public func shutdown() {
        autoLearn.cancel() // drop any pending read-back; no AX on the way out
        (engine as? LocalServerEngine)?.shutdown()
        chatServer?.shutdown()
        chatServer = nil
    }

    /// Called when the user clicks the Dock icon (no windows open).
    public func handleReopen() {
        showWindow()
    }

    private func showWindow() {
        statusWindow.show()
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(config.showDockIcon ? .regular : .accessory)
        if config.showDockIcon {
            statusWindow.show() // give the Dock icon a window to front
        }
    }

    private func toggleDockIcon() {
        config.showDockIcon.toggle()
        try? config.save()
        applyActivationPolicy()
        if !config.showDockIcon {
            statusWindow.window?.orderOut(nil)
        }
        refreshMenu()
        Log.info("dock icon \(config.showDockIcon ? "shown" : "hidden")")
    }

    // MARK: state machine

    private func dispatch(_ event: FnStateMachine.Event) {
        let action = machine.handle(event)
        if action != .none {
            Log.info("action: \(action)")
        }
        switch action {
        case .none:
            break
        case .startRecording:
            beginRecording()
        case .cancelRecording:
            stopMaxDurationTimer()
            recorder.cancel()
            recorder.onChunk = nil
            streamSession?.cancel()
            streamSession = nil
            hud.hide()
        case .stopAndProcess:
            stopMaxDurationTimer()
            processUtterance()
        case .flashBusy:
            hud.flash(.busy)
        }
        updateIcon()
    }

    private func beginRecording() {
        guard let engine else {
            _ = machine.handle(.abort)
            recorder.cancel()
            hud.flash(.error(engineHint ?? "Transcription engine not configured"), for: 2.5)
            return
        }
        guard PermissionsManager.microphoneAuthorized() else {
            _ = machine.handle(.abort)
            hud.flash(.error("Microphone permission needed"), for: 2.5)
            Task { _ = await PermissionsManager.requestMicrophoneAccess() }
            return
        }
        // Capture which app we're dictating into now (focus is stable during the
        // hold — the global hotkey doesn't steal it), to pick vocabulary later.
        let front = NSWorkspace.shared.frontmostApplication
        dictationContext = AppContext.classify(bundleID: front?.bundleIdentifier,
                                               appName: front?.localizedName)
        dictationPID = front?.processIdentifier
        do {
            // Streaming engines (Kyutai) open a session and feed audio live during
            // the hold; batch engines accumulate Int16 and transcribe on release.
            if let streaming = engine as? StreamingTranscriptionEngine {
                let session = try streaming.makeSession()
                // Don't paint live partials on screen while a secure field is
                // focused — a dictated password must not be shown/screen-captured.
                session.onPartial = { [weak self] text in
                    self?.hud.updateLiveText(isSecureInputActive() ? "" : text)
                }
                streamSession = session
                recorder.outputMode = .streamingFloat32
                recorder.onChunk = { [weak self] pcm in self?.streamSession?.append(pcm) }
            } else {
                recorder.outputMode = .batchInt16
                recorder.onChunk = nil
            }
            try recorder.start()
            hud.show(.listening)
            startMaxDurationTimer()
            // Second chance for the previous utterance's read-back: the field
            // is about to change. Deferred a runloop turn so the AX round trip
            // can never delay the recorder or the HUD (audio is already being
            // captured on the tap thread).
            DispatchQueue.main.async { [weak self] in self?.autoLearn.flushPending() }
        } catch {
            streamSession?.cancel()
            streamSession = nil
            recorder.onChunk = nil
            _ = machine.handle(.abort)
            hud.flash(.error(error.localizedDescription), for: 2.5)
        }
    }

    private func processUtterance() {
        let samples = recorder.stop()
        recorder.onChunk = nil
        hud.show(.processing)
        let cleaner = config.cleanupEnabled ? self.cleaner : nil

        // Streaming path (Kyutai): finalize the session opened on key-down.
        if let session = streamSession {
            streamSession = nil
            pipelineTask = Task { @MainActor [weak self] in
                defer {
                    self?.pipelineTask = nil
                    self?.dispatch(.pipelineFinished)
                }
                do {
                    let start = Date()
                    let raw = try await session.finish()
                    Log.info("kyutai finalized in "
                        + "\(String(format: "%.2f", -start.timeIntervalSinceNow))s: \(raw.count) chars")
                    await self?.deliver(raw: raw, cleaner: cleaner, since: start)
                } catch {
                    Log.info("pipeline error: \(error.localizedDescription)")
                    self?.hud.flash(.error(error.localizedDescription), for: 2.5)
                }
            }
            return
        }

        // Batch path (Groq / whisper.cpp).
        guard let batch = engine as? TranscriptionEngine else {
            dispatch(.pipelineFinished)
            return
        }
        let context = dictationContext
        let prompt = VocabularyPrompt.whisperPrompt(config.vocabulary(for: context))
        pipelineTask = Task { @MainActor [weak self] in
            defer {
                self?.pipelineTask = nil
                self?.dispatch(.pipelineFinished)
            }
            let duration = Double(samples.count) / AudioRecorder.targetSampleRate
            guard duration >= 0.3 else {
                self?.hud.hide()
                return
            }
            // Energy gate before transcription: silent / muted-mic captures make
            // Whisper hallucinate canned phrases, so skip the round-trip entirely.
            guard AudioRecorder.hasSpeechEnergy(samples) else {
                self?.hud.flash(.error("No speech detected"))
                return
            }
            // Condition the (non-silent) audio: strip DC offset and normalize the
            // level so soft/variable speech reaches the model consistently.
            let conditioned = AudioRecorder.normalize(samples)
            let wav = WAVEncoder.encode(samples: conditioned,
                                        sampleRate: UInt32(AudioRecorder.targetSampleRate))
            Log.info("utterance: \(String(format: "%.1f", duration))s audio, \(wav.count) bytes")
            do {
                let start = Date()
                let raw = try await batch.transcribe(wav: wav, prompt: prompt)
                Log.info("transcribed (\(context.rawValue)) in "
                    + "\(String(format: "%.2f", -start.timeIntervalSinceNow))s: \(raw.count) chars")
                await self?.deliver(raw: raw, cleaner: cleaner, since: start)
            } catch {
                Log.info("pipeline error: \(error.localizedDescription)")
                self?.hud.flash(.error(error.localizedDescription), for: 2.5)
            }
        }
    }

    /// Shared pipeline tail: optional Groq cleanup → paste → HUD feedback.
    @MainActor
    private func deliver(raw: String, cleaner: Cleaner?, since start: Date) async {
        guard !raw.isEmpty else {
            hud.flash(.error("No speech detected"))
            return
        }
        // Bound what reaches the pasteboard/keystroke path: a real utterance is
        // far under this, but a hostile/compromised STT server could return
        // megabytes.
        let bounded = String(raw.prefix(Self.maxTranscriptChars))
        // Corrector before the LLM (it sees canonical spellings) and after
        // (repairs casing the LLM flattened); idempotent, and the only repair
        // layer when no cleanup LLM is available.
        let corrected = corrector.correct(bounded)
        let text: String
        if let cleaner {
            text = corrector.correct(await cleaner.cleanOrFallback(corrected))
        } else {
            text = corrected
        }
        let outcome = inserter.insert(text)
        Log.info("inserted (\(outcome == .pasted ? "pasted" : "clipboard-only")) "
            + "after \(String(format: "%.2f", -start.timeIntervalSinceNow))s total")
        if outcome == .pasted {
            hud.flash(.done, for: 0.9)
            if let pid = dictationPID, pid != ProcessInfo.processInfo.processIdentifier {
                autoLearn.schedule(pasted: text, pid: pid, context: dictationContext)
            }
        } else {
            hud.flash(.copiedSecureInput, for: 3.0) // secure input: never scheduled
        }
    }

    /// Vocabulary-only refresh after auto-learn adds a term: rebuilds the
    /// deterministic corrector and re-bakes the cleanup LLM's spelling rule
    /// WITHOUT touching any child server (`rebuildCleanup()` would terminate
    /// and cold-reload the llama.cpp GGUF). The Whisper prompt needs nothing —
    /// it's built per utterance from `config.vocabulary(for:)`.
    private func refreshVocabulary() {
        corrector = TranscriptCorrector(terms: config.cleanupVocabulary,
                                        aliases: config.effectiveAliases)
        cleaner = cleaner?.withVocabulary(config.cleanupVocabulary)
    }

    private func applyLearnedTerm(_ change: LearnedChange) {
        if let evicted = change.evicted {
            let evictedKey = TranscriptCorrector.key(evicted)
            config.customVocabulary.removeAll { TranscriptCorrector.key($0) == evictedKey }
            config.codeVocabulary.removeAll { TranscriptCorrector.key($0) == evictedKey }
        }
        // The user may have hand-added it since the candidate was counted.
        let keys = CorrectionMiner.vocabularyKeys(config.cleanupVocabulary)
        guard !keys.contains(TranscriptCorrector.key(change.term)) else { return }
        if change.context == .code {
            config.codeVocabulary.append(change.term)
        } else {
            config.customVocabulary.append(change.term)
        }
        try? config.save()
        refreshVocabulary()
        Log.info("auto-learn: \"\(change.term)\" → "
            + (change.context == .code ? "codeVocabulary" : "customVocabulary"))
    }

    // MARK: max-duration cutoff

    private func startMaxDurationTimer() {
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: config.maxRecordSeconds,
                                                repeats: false) { [weak self] _ in
            self?.dispatch(.maxDurationReached(at: Date()))
        }
    }

    private func stopMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    // MARK: engine / menu plumbing

    private func makeGroqClient() -> GroqClient? {
        guard let key = config.groqAPIKey, !key.isEmpty else { return nil }
        return GroqClient(apiKey: key, sttModel: config.sttModel,
                          chatModel: config.cleanupModel, language: config.language)
    }

    /// Cleanup runs independently of the STT engine, in any app context: the
    /// deterministic corrector always rebuilds from the full vocabulary union,
    /// and the LLM pass is llama.cpp- or Groq-backed per `cleanupEngine`.
    /// When the LLM side is unavailable the corrector still repairs terms and
    /// raw transcripts are inserted; a missing cleanup model never blocks
    /// dictation (that's why failures set `cleanupHint`, not `engineHint`).
    private func rebuildCleanup() {
        chatServer?.shutdown()
        chatServer = nil
        cleaner = nil
        cleanupHint = nil
        corrector = TranscriptCorrector(terms: config.cleanupVocabulary,
                                        aliases: config.effectiveAliases)
        guard config.cleanupEnabled else {
            cleanupHint = "disabled"
            return
        }
        switch config.cleanupEngine {
        case .groq:
            if let groq = makeGroqClient() {
                cleaner = Cleaner(chat: groq, vocabulary: config.cleanupVocabulary)
            } else {
                cleanupHint = "no Groq API key"
            }
        case .local:
            let model = (config.llamaModelPath as NSString).expandingTildeInPath
            if !FileManager.default.isExecutableFile(atPath: config.llamaBinaryPath) {
                cleanupHint = "llama-server missing — run scripts/install_llama.sh"
            } else if !FileManager.default.fileExists(atPath: model) {
                cleanupHint = "cleanup model missing — run scripts/install_llama.sh"
            } else {
                let chat = LlamaCppChatEngine(binaryPath: config.llamaBinaryPath,
                                              modelPath: config.llamaModelPath,
                                              port: config.llamaPort)
                chat.warmUp()
                chatServer = chat
                cleaner = Cleaner(chat: chat, vocabulary: config.cleanupVocabulary)
            }
        }
    }

    private func rebuildEngine() {
        (engine as? LocalServerEngine)?.shutdown()
        rebuildCleanup()

        switch config.engine {
        case .groq:
            let groqClient = makeGroqClient()
            engine = groqClient
            engineHint = groqClient == nil ? "Set your Groq API key (menu bar icon)" : nil
        case .whisperCpp:
            let modelPath = (config.whisperModelPath as NSString).expandingTildeInPath
            if !FileManager.default.isExecutableFile(atPath: config.whisperBinaryPath) {
                engine = nil
                engineHint = "whisper-server missing — brew install whisper-cpp"
            } else if !FileManager.default.fileExists(atPath: modelPath) {
                engine = nil
                engineHint = "Whisper model missing — see README"
            } else {
                let local = WhisperCppEngine(binaryPath: config.whisperBinaryPath,
                                             modelPath: config.whisperModelPath,
                                             port: config.whisperPort,
                                             language: config.language)
                local.warmUp()
                engine = local
                engineHint = nil
            }
        case .kyutai:
            let binary = (config.kyutaiBinaryPath as NSString).expandingTildeInPath
            let kyutaiConfig = Self.kyutaiConfigPath(config)
            if !FileManager.default.isExecutableFile(atPath: binary) {
                engine = nil
                engineHint = "moshi-server missing — run scripts/install_kyutai.sh"
            } else if !FileManager.default.fileExists(atPath: kyutaiConfig) {
                engine = nil
                engineHint = "Kyutai config missing — run scripts/install_kyutai.sh"
            } else {
                let kyutai = KyutaiStreamingEngine(binaryPath: binary, configPath: kyutaiConfig,
                                                   port: config.kyutaiPort, apiKey: config.kyutaiApiKey)
                kyutai.warmUp()
                engine = kyutai
                engineHint = nil
            }
        }
    }

    /// Resolves the moshi-server STT config path (user override or app-managed default).
    private static func kyutaiConfigPath(_ config: Config) -> String {
        if let override = config.kyutaiConfigPath, !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur/kyutai/moshi-stt.toml")
            .path
    }

    private func selectEngine(_ kind: EngineKind) {
        guard kind != config.engine else { return }
        config.engine = kind
        try? config.save()
        rebuildEngine()
        refreshMenu()
        Log.info("engine switched to \(config.engine.rawValue)")
    }

    private func updateIcon() {
        guard engine != nil else {
            statusItem.setIcon(.needsSetup)
            return
        }
        switch machine.state {
        case .idle: statusItem.setIcon(.idle)
        case .recording: statusItem.setIcon(.recording)
        case .processing: statusItem.setIcon(.processing)
        }
    }

    private func refreshMenu() {
        let status = engineHint.map { "⚠️ \($0)" } ?? "\(config.engine.displayName), ready"
        statusItem.setInfo("Murmur — hold \(config.hotkey.displayName) to dictate (\(status))")
        statusItem.setSelectedEngine(config.engine)
        statusItem.setCleanupChecked(config.cleanupEnabled)
        statusItem.setDockIconChecked(config.showDockIcon)
        statusItem.setLaunchAtLoginChecked(SMAppService.mainApp.status == .enabled)
        statusWindow.update(
            statusText: "Hold \(config.hotkey.displayName) to dictate · \(status)",
            selectedEngine: config.engine)
        updateIcon()
    }

    private func toggleCleanup() {
        config.cleanupEnabled.toggle()
        try? config.save()
        rebuildCleanup() // off kills the local LLM child; STT stays warm
        refreshMenu()
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showInfoAlert(title: "Launch at Login unavailable",
                          text: "Registration failed (\(error.localizedDescription)). "
                              + "This only works from the installed Murmur.app, and may need "
                              + "approval in System Settings → General → Login Items.")
        }
        refreshMenu()
    }

    private func promptForAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Groq API Key"
        alert.informativeText = "Paste your key from console.groq.com/keys.\n"
            + "Stored locally in ~/.config/murmur/config.json."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "gsk_…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            config.groqAPIKey = key
            do {
                try config.save()
            } catch {
                showInfoAlert(title: "Could not save config",
                              text: error.localizedDescription)
            }
            rebuildEngine()
        }
        refreshMenu()
    }

    private func warnAboutFnSetting() {
        let alert = NSAlert()
        alert.messageText = "fn key may trigger system actions"
        alert.informativeText = "Murmur uses fn as push-to-talk, but macOS currently has an "
            + "action bound to the fn key. Set System Settings → Keyboard → "
            + "“Press 🌐 key to” → “Do Nothing”."
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showInfoAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
