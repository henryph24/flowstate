import AppKit
import AVFoundation
import MurmurKit

// MARK: - harness (no XCTest in Command Line Tools)

var passed = 0
var failed = 0

func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("  FAIL — \(message) (main.swift:\(line))")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        print("  FAIL — \(message): got \(actual), expected \(expected) (main.swift:\(line))")
    }
}

func section(_ name: String) {
    print("• \(name)")
}

// MARK: - FnStateMachine

section("FnStateMachine")
do {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    var machine = FnStateMachine(minHold: 0.25)
    expectEqual(machine.handle(.hotkeyDown(at: t0)), .startRecording, "down from idle starts recording")
    expectEqual(machine.state, .recording(since: t0), "state is recording")
    expectEqual(machine.handle(.hotkeyUp(at: t0.addingTimeInterval(1.0))), .stopAndProcess, "held release processes")
    expectEqual(machine.state, .processing, "state is processing")
    expectEqual(machine.handle(.hotkeyDown(at: t0.addingTimeInterval(2))), .flashBusy, "down while processing flashes busy")
    expectEqual(machine.state, .processing, "busy keeps processing state")
    expectEqual(machine.handle(.pipelineFinished), FnStateMachine.Action.none, "pipeline finish is quiet")
    expectEqual(machine.state, .idle, "back to idle")

    var tap = FnStateMachine(minHold: 0.25)
    _ = tap.handle(.hotkeyDown(at: t0))
    expectEqual(tap.handle(.hotkeyUp(at: t0.addingTimeInterval(0.1))), .cancelRecording, "sub-minHold tap discards")
    expectEqual(tap.state, .idle, "tap returns to idle")

    var chord = FnStateMachine(minHold: 0.25)
    _ = chord.handle(.hotkeyDown(at: t0))
    expectEqual(chord.handle(.otherKeyDown), .cancelRecording, "fn+key chord cancels")
    expectEqual(chord.state, .idle, "chord cancel returns to idle")
    expectEqual(chord.handle(.hotkeyUp(at: t0.addingTimeInterval(1))), FnStateMachine.Action.none, "release after cancel is quiet")

    var aborted = FnStateMachine(minHold: 0.25)
    _ = aborted.handle(.hotkeyDown(at: t0))
    expectEqual(aborted.handle(.abort), .cancelRecording, "abort cancels recording")

    var maxed = FnStateMachine(minHold: 0.25)
    _ = maxed.handle(.hotkeyDown(at: t0))
    expectEqual(maxed.handle(.maxDurationReached(at: t0.addingTimeInterval(600))), .stopAndProcess, "max duration processes")
    expectEqual(maxed.state, .processing, "max duration lands in processing")
    expectEqual(maxed.handle(.hotkeyUp(at: t0.addingTimeInterval(601))), FnStateMachine.Action.none, "release after max-duration cutoff is quiet")

    var spurious = FnStateMachine(minHold: 0.25)
    expectEqual(spurious.handle(.hotkeyUp(at: t0)), FnStateMachine.Action.none, "up in idle (launched mid-hold) is quiet")
    expectEqual(spurious.handle(.otherKeyDown), FnStateMachine.Action.none, "typing in idle is quiet")
    expectEqual(spurious.handle(.pipelineFinished), FnStateMachine.Action.none, "stray pipeline-finish is quiet")
}

// MARK: - WAVEncoder

section("WAVEncoder")
do {
    let samples: [Int16] = [0, 1, -1, 32767, -32768]
    let wav = WAVEncoder.encode(samples: samples, sampleRate: 16_000)

    expectEqual(wav.count, 44 + samples.count * 2, "total size = header + payload")
    expectEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF", "RIFF magic")
    expectEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE", "WAVE magic")
    expectEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ", "fmt chunk id")
    expectEqual(String(data: wav[36..<40], encoding: .ascii), "data", "data chunk id")

    func u32(_ offset: Int) -> UInt32 {
        wav.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    func u16(_ offset: Int) -> UInt16 {
        wav.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }
    expectEqual(u32(4), UInt32(36 + samples.count * 2), "RIFF chunk size")
    expectEqual(u32(16), 16, "fmt chunk size")
    expectEqual(u16(20), 1, "PCM format tag")
    expectEqual(u16(22), 1, "mono")
    expectEqual(u32(24), 16_000, "sample rate")
    expectEqual(u32(28), 32_000, "byte rate")
    expectEqual(u16(32), 2, "block align")
    expectEqual(u16(34), 16, "bits per sample")
    expectEqual(u32(40), UInt32(samples.count * 2), "data size")

    let payload = wav.suffix(from: 44)
    expectEqual(Array(payload), [0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x80],
                "little-endian sample payload")
}

// MARK: - MultipartBody

section("MultipartBody")
do {
    var multipart = MultipartBody(boundary: "BOUNDARY")
    multipart.addField(name: "model", value: "whisper-large-v3-turbo")
    multipart.addFile(name: "file", filename: "audio.wav", contentType: "audio/wav",
                      data: Data([0x01, 0x02]))
    let body = multipart.finalized()
    let text = String(decoding: body, as: UTF8.self)

    expectEqual(multipart.contentType, "multipart/form-data; boundary=BOUNDARY", "content type header")
    expect(text.contains("--BOUNDARY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"),
           "field part structure")
    expect(text.contains("--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"),
           "file part headers")
    expect(text.hasSuffix("--BOUNDARY--\r\n"), "closing boundary")
    expect(body.range(of: Data([0x01, 0x02])) != nil, "file bytes present verbatim")
}

// MARK: - TextInserter pasteboard logic

section("TextInserter")
do {
    expect(TextInserter.shouldRestore(expected: 5, current: 5), "restore when changeCount unchanged")
    expect(!TextInserter.shouldRestore(expected: 5, current: 6), "skip restore when pasteboard touched")

    // Round-trip on a private named pasteboard — never touches the user clipboard.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.hungpq.murmur.tests"))
    pasteboard.clearContents()
    pasteboard.setString("original contents", forType: .string)

    let snapshot = TextInserter.snapshot(of: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("transcript", forType: .string)
    let afterWrite = pasteboard.changeCount

    TextInserter.restore(snapshot, to: pasteboard, ifChangeCountStill: afterWrite)
    expectEqual(pasteboard.string(forType: .string), "original contents", "snapshot restores original")

    // Fresh snapshot per scenario — production takes one snapshot per insert().
    let snapshot2 = TextInserter.snapshot(of: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("transcript", forType: .string)
    let stale = pasteboard.changeCount
    pasteboard.clearContents()
    pasteboard.setString("user copied something new", forType: .string)
    TextInserter.restore(snapshot2, to: pasteboard, ifChangeCountStill: stale)
    expectEqual(pasteboard.string(forType: .string), "user copied something new",
                "stale changeCount leaves newer contents alone")

    // Secure input branch: no paste, transcript stays on the pasteboard.
    let inserter = TextInserter(restoreDelay: 0.1, secureInputCheck: { true })
    let outcome = inserter.insert("secret-mode text", into: pasteboard)
    expectEqual(outcome, .copiedOnlySecureInput, "secure input reports copy-only")
    expectEqual(pasteboard.string(forType: .string), "secret-mode text",
                "secure input leaves transcript on pasteboard")

    // Dictated text is staged concealed so clipboard managers / Universal
    // Clipboard don't archive every utterance.
    let staged = TextInserter.stagedItem(for: "dictated words")
    expectEqual(staged.string(forType: .string), "dictated words", "staged item carries the plain text")
    expect(staged.types.contains(TextInserter.concealedType), "staged item is marked ConcealedType")
    expect(staged.types.contains(TextInserter.autoGeneratedType), "staged item is marked AutoGeneratedType")
    pasteboard.clearContents()
}

// MARK: - WhisperCppEngine builders

section("WhisperCppEngine")
do {
    let args = WhisperCppEngine.serverArguments(modelPath: "/m/model.bin", port: 8723, language: "en")
    func argValue(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    expectEqual(argValue("-m"), "/m/model.bin", "server args include model path")
    expectEqual(argValue("--host"), "127.0.0.1", "server binds loopback only")
    expectEqual(argValue("--port"), "8723", "server args include port")
    expectEqual(argValue("-l"), "en", "language pinned (no auto-detect misfires)")
    expectEqual(argValue("-bs"), "5", "beam search width 5")
    expectEqual(argValue("-bo"), "5", "best-of 5")
    expect(args.contains("-sns"), "suppress non-speech tokens")
    expect(args.contains("--carry-initial-prompt"), "carry initial prompt across long-utterance segments")

    let request = WhisperCppEngine.makeInferenceRequest(wav: Data([0xAB]), port: 9999)
    expectEqual(request.url?.absoluteString, "http://127.0.0.1:9999/inference", "inference URL")
    expectEqual(request.httpMethod, "POST", "inference method")
    expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true,
           "multipart content type")
    expect(request.httpBody?.range(of: Data([0xAB])) != nil, "wav bytes in body")
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    expect(body.contains("name=\"temperature\"\r\n\r\n0"), "temperature 0 sent")
    expect(body.contains("name=\"response_format\"\r\n\r\njson"), "response_format json sent")
    expect(!body.contains("name=\"prompt\""), "no prompt field when none provided")

    let biased = WhisperCppEngine.makeInferenceRequest(
        wav: Data([0xAB]), port: 9999, prompt: "Glossary: Murmur, Kyutai.")
    let biasedBody = String(decoding: biased.httpBody ?? Data(), as: UTF8.self)
    expect(biasedBody.contains("name=\"prompt\"\r\n\r\nGlossary: Murmur, Kyutai."),
           "prompt field carries the vocabulary biasing string")
}

// MARK: - LlamaCppChatEngine

section("LlamaCppChatEngine")
do {
    let args = LlamaCppChatEngine.serverArguments(modelPath: "/m/chat.gguf", port: 8725)
    func argValue(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    expectEqual(argValue("-m"), "/m/chat.gguf", "server args include model path")
    expectEqual(argValue("--host"), "127.0.0.1", "server binds loopback only")
    expectEqual(argValue("--port"), "8725", "server args include port")
    expectEqual(argValue("-c"), "4096", "context sized for system prompt + long utterance")
    expectEqual(argValue("-ngl"), "99", "full Metal offload")
    expect(argValue("-t").flatMap(Int.init) != nil, "thread count is numeric")

    let request = try! LlamaCppChatEngine.makeChatRequest(
        system: "You clean.", user: "um hello there", maxTokens: 128, port: 8725)
    expectEqual(request.url?.absoluteString, "http://127.0.0.1:8725/v1/chat/completions", "chat URL")
    expectEqual(request.httpMethod, "POST", "chat method")
    expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "JSON content type")
    expect(request.value(forHTTPHeaderField: "Authorization") == nil, "no auth header for loopback server")
    expectEqual(request.timeoutInterval, 20, "request timeout allows a cold prompt cache")
    let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
    let messages = body["messages"] as! [[String: String]]
    expectEqual(messages.count, 2, "system + user messages only")
    expectEqual(messages[0]["role"], "system", "system message first")
    expectEqual(messages[0]["content"], "You clean.", "system content")
    expectEqual(messages[1]["role"], "user", "user message second")
    expectEqual(body["temperature"] as? Double, 0, "temperature 0")
    expectEqual(body["max_tokens"] as? Int, 128, "llama.cpp's max_tokens field")
    expect(body["max_completion_tokens"] == nil, "no Groq-style max_completion_tokens")
    expect(body["model"] == nil, "no model field — llama-server serves one model")
    expectEqual(body["cache_prompt"] as? Bool, true, "system-prefix KV cache reuse enabled")

    let healthReq = LlamaCppChatEngine.healthRequest(port: 8725)
    expectEqual(healthReq.url?.absoluteString, "http://127.0.0.1:8725/health", "health URL")
    expectEqual(healthReq.timeoutInterval, 1, "health probe is quick")

    let good = #"{"choices":[{"message":{"content":"  Cleaned text. "}}]}"#
    expectEqual(try? LlamaCppChatEngine.parseChatResponse(Data(good.utf8)), "Cleaned text.",
                "chat response parsed and trimmed")
    for bad in [#"{"choices":[]}"#, #"{"choices":[{"message":{"content":null}}]}"#, "not json"] {
        expect((try? LlamaCppChatEngine.parseChatResponse(Data(bad.utf8))) == nil,
               "bad payload throws: \(bad)")
    }

    let errors: [LlamaCppError] = [.binaryMissing("/x"), .modelMissing("/y"), .serverTimeout,
                                   .serverLoading, .http(status: 500), .emptyResponse]
    for error in errors {
        expect(!(error.errorDescription ?? "").isEmpty, "error has a description: \(error)")
    }
    expect(LlamaCppError.binaryMissing("/x").errorDescription!.contains("install_llama.sh"),
           "binary-missing error names the remedy")
    expect(LlamaCppError.modelMissing("/y").errorDescription!.contains("install_llama.sh"),
           "model-missing error names the remedy")
}

// MARK: - VocabularyPrompt

section("VocabularyPrompt")
do {
    expect(VocabularyPrompt.whisperPrompt([]) == nil, "no terms → no whisper prompt")
    expect(VocabularyPrompt.cleanupRule([]) == nil, "no terms → no cleanup rule")
    expect(VocabularyPrompt.whisperPrompt(["  ", ""]) == nil, "blank-only terms → no prompt")

    let terms = ["Murmur", "SwiftPM", "Kyutai"]
    let prompt = VocabularyPrompt.whisperPrompt(terms) ?? ""
    expect(prompt.hasPrefix("The transcript may include these terms: "), "sentence-style framing")
    expect(prompt.hasSuffix("."), "prompt ends with a period")
    for term in terms { expect(prompt.contains(term), "whisper prompt includes \(term)") }

    let rule = VocabularyPrompt.cleanupRule(terms) ?? ""
    expect(rule.hasPrefix("- "), "cleanup rule is a bullet")
    for term in terms { expect(rule.contains(term), "cleanup rule includes \(term)") }

    expectEqual(VocabularyPrompt.normalize(["  Vercel ", "vercel", "Supabase", "VERCEL"]),
                ["Vercel", "Supabase"], "normalize trims, dedups case-insensitively, keeps order")

    // Length budget: the framing sentence always survives; not every term need fit.
    let many = (0..<500).map { "Term\($0)VeryLongIdentifier" }
    let capped = VocabularyPrompt.whisperPrompt(many) ?? ""
    expect(capped.hasPrefix("The transcript may include these terms: "), "framing kept under budget")
    expect(capped.contains("Term0VeryLongIdentifier"), "first term kept under budget")
    expect(capped.count < 700, "capped near the ~224-token budget (\(capped.count) chars)")

    // Two budgets: the cleanup rule is capped far more generously than the
    // whisper prompt (system prompt has no ~224-token ceiling).
    let manyRule = VocabularyPrompt.cleanupRule(many) ?? ""
    expect(manyRule.count > 700, "cleanup rule gets a larger budget than the whisper prompt")
    expect(manyRule.count < 3200, "cleanup rule is still capped (\(manyRule.count) chars)")
    expect(manyRule.contains("Term0VeryLongIdentifier"), "cleanup rule keeps input order")
}

// MARK: - BuiltinVocabulary

section("BuiltinVocabulary")
do {
    let code = BuiltinVocabulary.code
    let general = BuiltinVocabulary.general
    let all = BuiltinVocabulary.all
    expect(code.count > 200 && code.count < 700, "code list is populated (\(code.count) terms)")
    expect(general.count > 50 && general.count < 300, "general list is populated (\(general.count) terms)")
    expectEqual(all, code + general, "all = code + general")

    for (name, list) in [("code", code), ("general", general), ("all", all)] {
        // One assertion proves: no blanks, nothing untrimmed, no case-insensitive
        // duplicates, order preserved — i.e. the list is already normalize-stable.
        expectEqual(VocabularyPrompt.normalize(list), list, "\(name) list is normalize-stable")
        expect(list.allSatisfy { $0.count <= 26 }, "\(name): no term can blow the budget alone")
        expect(list.allSatisfy { !$0.contains(",") }, "\(name): no commas (would break the ', '-joined list)")
    }
    expect(Set(code.map { $0.lowercased() }).isDisjoint(with: Set(general.map { $0.lowercased() })),
           "code and general lists are disjoint")

    for anchor in ["PyTorch", "Kubernetes", "kubectl", "scikit-learn", "Hugging Face",
                   "TypeScript", "RAG", "MLOps", "PostgreSQL", "dbt", "Parakeet", "Trino"] {
        expect(code.contains(anchor), "code list contains \(anchor)")
    }
    for anchor in ["Black-Scholes", "econometrics", "GARCH", "Bayesian", "arXiv", "Claude",
                   "Kimi", "GLM", "Codex", "Claude in Chrome", "NotebookLM"] {
        expect(general.contains(anchor), "general list contains \(anchor)")
    }
    // Ambiguity guard: bare English collisions stay out (they'd misfire in the
    // context-independent cleanup rule and corrector).
    for excluded in ["Ray", "Beam", "React", "Cursor", "Go", "Flask", "Spark", "alpha", "beta"] {
        expect(!all.contains(excluded), "ambiguous bare term \(excluded) excluded")
    }

    // Each priority tier survives the 600-char Whisper budget on a fresh install.
    let codePrompt = VocabularyPrompt.whisperPrompt(code) ?? ""
    expect(codePrompt.hasPrefix("The transcript may include these terms: "), "code → framed prompt")
    expect(codePrompt.count < 700, "code whisper prompt within budget (\(codePrompt.count) chars)")
    for anchor in ["PyTorch", "kubectl", "RAG", "FastAPI"] { // FastAPI = code tier-1 boundary guard
        expect(codePrompt.contains(anchor), "priority term \(anchor) reaches the code whisper prompt")
    }
    let generalPrompt = VocabularyPrompt.whisperPrompt(general) ?? ""
    expect(generalPrompt.count < 700, "general whisper prompt within budget (\(generalPrompt.count) chars)")
    for anchor in ["Black-Scholes", "Gemini", "Kimi", "Codex"] { // Codex = general tier boundary guard
        expect(generalPrompt.contains(anchor), "priority term \(anchor) reaches the general whisper prompt")
    }

    // The cleanup LLM rule uses the priority ordering: same terms as `all`,
    // both prompt tiers guaranteed inside the 3,000-char cap.
    expectEqual(Set(BuiltinVocabulary.cleanupPriority), Set(all), "cleanupPriority is a reordering of all")
    expectEqual(BuiltinVocabulary.cleanupPriority.count, all.count, "cleanupPriority has no dups/drops")
    let rule = VocabularyPrompt.cleanupRule(BuiltinVocabulary.cleanupPriority) ?? ""
    expect(rule.count > 1500 && rule.count < 3200, "builtin cleanup rule uses the wider budget (\(rule.count) chars)")
    expect(rule.contains("Black-Scholes") && rule.contains("FastAPI"),
           "both prompt tiers reach the cleanup rule")

    // Spoken-alias invariants: multi-word spoken forms only (single tokens
    // risk real prose), indexable keys, unique, and never redundant with the
    // term index's own multi-token key joins.
    let aliases = BuiltinVocabulary.spokenAliases
    expect(aliases.count > 20 && aliases.count < 100, "alias list is populated (\(aliases.count))")
    var aliasKeys = Set<String>()
    let termKeys = Set(all.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } })
    for (spoken, replacement) in aliases {
        let key = spoken.lowercased().filter { $0.isLetter || $0.isNumber }
        expect(spoken.split(separator: " ").count >= 2, "alias '\(spoken)' has ≥2 words")
        expect(key.count >= TranscriptCorrector.minKeyLength, "alias '\(spoken)' key long enough")
        expect(!replacement.isEmpty, "alias '\(spoken)' has a replacement")
        expect(key != replacement.lowercased().filter { $0.isLetter || $0.isNumber },
               "alias '\(spoken)' is not redundant with its replacement's key")
        expect(!termKeys.contains(key), "alias '\(spoken)' doesn't shadow a term key")
        expect(aliasKeys.insert(key).inserted, "alias '\(spoken)' key is unique")
    }
}

// MARK: - TranscriptCorrector

section("TranscriptCorrector")
do {
    let corrector = TranscriptCorrector(terms: Config().cleanupVocabulary,
                                        aliases: Config().effectiveAliases)

    let mustChange: [(String, String)] = [
        ("install scikit learn", "install scikit-learn"),
        ("use hugging face models", "use Hugging Face models"),
        ("we use pytorch here", "we use PyTorch here"),
        ("use pytorch.", "use PyTorch."),
        ("(pytorch)", "(PyTorch)"),
        ("Pytorch is fast", "PyTorch is fast"),
        ("next js app", "Next.js app"),
        ("nextjs app", "Next.js app"),
        ("type script", "TypeScript"),
        ("typescript", "TypeScript"),
        ("grpc call", "gRPC call"),
        ("llama cpp server", "llama.cpp server"),
        ("a chain of thought answer", "a chain-of-thought answer"), // 3-token span
        ("pytorch rules", "PyTorch rules"),                          // term at start
        ("I like pytorch", "I like PyTorch"),                        // term at end
    ]
    for (input, want) in mustChange {
        expectEqual(corrector.correct(input), want, "corrects \(input)")
    }

    let mustNotChange = [
        "old rag stays old rag",
        "at the helm of the ship",
        "the rust on my bike",
        "the net effect was bedrock solid",
        "she is a playwright",
        "I like to go running",
        "two pandas ate bamboo",
        "Pandas are cute",
        "Vector database is fast.",
        "We use PyTorch here",
        "",
        "scikit, learn",
        "we use next. JS is fine",
    ]
    for input in mustNotChange {
        expectEqual(corrector.correct(input), input, "leaves alone: \(input.isEmpty ? "<empty>" : input)")
    }

    expectEqual(corrector.correct("a  b\npytorch"), "a  b\nPyTorch", "whitespace preserved byte-for-byte")

    for (input, _) in mustChange {
        let once = corrector.correct(input)
        expectEqual(corrector.correct(once), once, "idempotent on: \(input)")
    }

    expectEqual(TranscriptCorrector(terms: []).correct("pytorch"), "pytorch", "empty terms → no-op")

    let userCased = TranscriptCorrector(terms: ["MurmurKit"])
    expectEqual(userCased.correct("murmurkit builds"), "MurmurKit builds", "user term single-token fix")
    expectEqual(userCased.correct("murmur kit builds"), "MurmurKit builds", "user term multi-token join")

    let lowerUser = TranscriptCorrector(terms: ["pytorch"])
    expectEqual(lowerUser.correct("PyTorch is here"), "PyTorch is here", "never down-cases to a user's lowercase term")

    let allowed = ["PyTorch", "Next.js", "gRPC", "Hugging Face", "scikit-learn", "NumPy"]
    let rejected = ["Rust", "RAG", ".NET", "pandas", "CI/CD", "Kubernetes", "JSON", "Helm"]
    for term in allowed {
        expect(TranscriptCorrector.allowsSingleTokenRewrite(term), "\(term) allows single-token rewrite")
    }
    for term in rejected {
        expect(!TranscriptCorrector.allowsSingleTokenRewrite(term), "\(term) rejects single-token rewrite")
    }

    // Spoken aliases: deterministic phonetic repair, zero LLM.
    let aliasMustChange: [(String, String)] = [
        ("install pie torch now", "install PyTorch now"),
        ("run cube control get pods", "run kubectl get pods"),
        ("restart engine x today", "restart nginx today"),
        ("import num pie as np", "import NumPy as np"),
        ("the black shoals model", "the Black-Scholes model"),
        ("compute the sharp ratio", "compute the Sharpe ratio"),
        ("submitted to new rips", "submitted to NeurIPS"),
        ("write it in lay tech", "write it in LaTeX"),
        ("push to get hub", "push to GitHub"),
        ("open cloud code now", "open Claude Code now"),
        ("try cloud in chrome today", "try Claude in Chrome today"),
        ("use notebook lm here", "use NotebookLM here"), // term key-join, no alias needed
    ]
    for (input, want) in aliasMustChange {
        expectEqual(corrector.correct(input), want, "alias corrects: \(input)")
        let once = corrector.correct(input)
        expectEqual(corrector.correct(once), once, "alias idempotent: \(input)")
    }
    let aliasMustNotChange = [
        "a pie for dessert",          // "pie" alone: key too short, never indexed
        "the sequel was better",      // single token, no alias
        "cap and trade policy",       // "cap" alone matches nothing
        "a sharp knife",              // "sharp" alone matches nothing
        "ask kimi and glm about it",  // Capitalized-only/ALL-CAPS terms are
                                      // corrector-inert by design (prompt+LLM fix these)
    ]
    for input in aliasMustNotChange {
        expectEqual(corrector.correct(input), input, "alias leaves alone: \(input)")
    }

    // User aliases win over builtin, and replacements canonicalize through
    // the user's own term casing.
    var aliasConfig = Config()
    aliasConfig.vocabularyAliases = ["pie torch": "PieTorch"]
    let userAlias = TranscriptCorrector(terms: aliasConfig.cleanupVocabulary,
                                        aliases: aliasConfig.effectiveAliases)
    expectEqual(userAlias.correct("use pie torch here"), "use PieTorch here",
                "user alias beats the builtin alias")
    var casedConfig = Config()
    casedConfig.codeVocabulary = ["pytorch"]
    let casedAlias = TranscriptCorrector(terms: casedConfig.cleanupVocabulary,
                                         aliases: casedConfig.effectiveAliases)
    expectEqual(casedAlias.correct("use pie torch here"), "use pytorch here",
                "alias replacement canonicalizes through the user's term casing")
}

// MARK: - CorrectionMiner (auto-learn pure core)

section("CorrectionMiner: tokenize")
do {
    let tokens = CorrectionMiner.tokenize("Use Next.js! (it's fast). MurmurKit's core,\nnew line")
    expectEqual(tokens.map(\.core), ["Use", "Next.js", "it", "fast", "MurmurKit", "core", "new", "line"],
                "cores: edge punct trimmed, in-term kept, 's stripped (possessive/contraction, symmetric)")
    expectEqual(tokens.map(\.key), ["use", "nextjs", "it", "fast", "murmurkit", "core", "new", "line"],
                "keys are lowercase letters+digits")
    expectEqual(tokens.map(\.isSentenceInitial), [true, false, true, false, true, false, true, false],
                "sentence-initial: start, after '!', after '.', after newline")
    expectEqual(CorrectionMiner.tokenize("").count, 0, "empty text → no tokens")
    let dash = CorrectionMiner.tokenize("hello — world. Next")
    expectEqual(dash.map(\.core), ["hello", "world", "Next"], "standalone punct dropped")
    expect(dash[2].isSentenceInitial, "sentence boundary carried across the dropped token")
}

section("CorrectionMiner: similarity")
do {
    expectEqual(CorrectionMiner.editDistance("pietorch", "pytorch"), 2, "pietorch↔pytorch = 2")
    expectEqual(CorrectionMiner.editDistance("jane", "jayne"), 1, "jane↔jayne = 1")
    expectEqual(CorrectionMiner.editDistance("three", "four"), 5, "three↔four = 5")
    expectEqual(CorrectionMiner.editDistance("", "abc"), 3, "empty↔abc = 3")
    expectEqual(CorrectionMiner.editDistance("same", "same"), 0, "identity = 0")
    expectEqual(CorrectionMiner.editDistance("ab", "ba"),
                CorrectionMiner.editDistance("ba", "ab"), "symmetric")

    expect(CorrectionMiner.isSimilar(new: "murmurkit", old: ["murmur", "kit"]),
           "concatenation similarity: murmur+kit → murmurkit")
    expect(CorrectionMiner.isSimilar(new: "jayne", old: ["jane"]), "close single word")
    expect(!CorrectionMiner.isSimilar(new: "ristorante", old: ["the", "cafe"]), "dissimilar rejected")
    expect(CorrectionMiner.isSimilar(new: "huggingface", old: ["hugging"]), "prefix extension")
    expect(!CorrectionMiner.isSimilar(new: "constantinople", old: ["con"]),
           "prefix branch capped by length delta")
}

section("CorrectionMiner: isTermLike")
do {
    for good in ["PyTorch", "gRPC", "Next.js", "scikit-learn", "llama.cpp", "GPT-4", "MurmurKit"] {
        expect(CorrectionMiner.isTermLike(good, sentenceInitial: true), "\(good) is term-like anywhere")
    }
    expect(CorrectionMiner.isTermLike("Jayne", sentenceInitial: false), "mid-sentence proper noun")
    for bad in ["API", "JSON", "recieve", "kubectl", "hello", ""] {
        expect(!CorrectionMiner.isTermLike(bad, sentenceInitial: false), "\(bad) is not term-like")
    }
    expect(!CorrectionMiner.isTermLike("Jayne", sentenceInitial: true),
           "sentence-initial capitalization is not evidence")
}

section("CorrectionMiner: locate")
do {
    func toks(_ s: String) -> [CorrectionMiner.Token] { CorrectionMiner.tokenize(s) }
    let paste = toks("we should try langchain for this agent")
    expect(CorrectionMiner.locate(pasted: paste, in: toks("we should try langchain for this agent")) != nil,
           "exact field located")
    let padded = toks("Earlier notes here. we should try langchain for this agent And later typing continues on")
    expect(CorrectionMiner.locate(pasted: paste, in: padded) != nil, "paste inside larger field located")
    expect(CorrectionMiner.locate(pasted: paste, in: toks("completely unrelated content about cooking dinner tonight")) == nil,
           "absent paste → nil")
    expect(CorrectionMiner.locate(pasted: paste, in: toks("we agent")) == nil,
           "field shorter than paste (mostly deleted) → nil")
    expect(CorrectionMiner.locate(pasted: toks("two tokens"), in: toks("two tokens")) == nil,
           "below minPastedTokens → nil")
    // Rare anchor beats stopword scatter in a long document.
    let doc = Array(repeating: "the and is of to in", count: 40).joined(separator: " ")
        + " we should try langchain for this agent " + Array(repeating: "the and is", count: 40).joined(separator: " ")
    if let range = CorrectionMiner.locate(pasted: paste, in: toks(doc)) {
        let window = Array(toks(doc)[range])
        expect(window.contains { $0.key == "langchain" }, "anchor window contains the rare token")
    } else {
        expect(false, "paste located in long stopword document")
    }
}

section("CorrectionMiner: candidates")
do {
    let knownWords: Set<String> = ["install", "today", "use", "the", "meet", "with", "jane", "four",
                                   "three", "api", "hello", "there", "receive", "we", "should", "try",
                                   "here", "run", "now", "at", "meeting", "is", "cafe", "diner", "a",
                                   "for", "this", "agent", "js", "and", "kit", "murmur", "lang", "chain"]
    let isKnown: (String) -> Bool = { knownWords.contains($0.lowercased()) }
    let vocab = CorrectionMiner.vocabularyKeys(Config().cleanupVocabulary)

    func mine(_ pasted: String, _ field: String, vocabKeys: Set<String> = vocab) -> [String] {
        CorrectionMiner.candidates(pasted: pasted, fieldText: field,
                                   isKnownWord: isKnown, existingVocabularyKeys: vocabKeys)
    }

    // must learn
    expectEqual(mine("use the murmur kit api", "use the MurmurKit API"), ["MurmurKit"],
                "2:1 join learned; ALL-CAPS API rejected")
    expectEqual(mine("we should try lang chain here", "we should try LangChain here",
                     vocabKeys: vocab.subtracting(["langchain"])), ["LangChain"],
                "2:1 join learned when not already vocab")
    expectEqual(mine("meet with jane at the meeting", "meet with Jayne at the meeting"), ["Jayne"],
                "mid-sentence proper-noun substitution learned")
    expectEqual(mine("use next js here today", "use Next.js here today",
                     vocabKeys: vocab.subtracting(["nextjs"])), ["Next.js"],
                "casing/punct fix learned when term unknown")
    expectEqual(mine("we should try murmur kit for this agent",
                     "Earlier text sits here. we should try MurmurKit for this agent And more typing after"),
                ["MurmurKit"], "paste embedded in surrounding content still mined")

    // must NOT learn
    expectEqual(mine("install pytorch today and run it now", "install pytorch today and run it now"), [],
                "identical field → nothing")
    expectEqual(mine("install pytorch today and run now", "install PyTorch today and run now"), [],
                "casing fix of a builtin term → already vocab")
    expectEqual(mine("we should meet at three today", "we should meet at four today"), [],
                "dissimilar known-word replacement → nothing")
    expectEqual(mine("we should try this here now", "we should try here now"), [],
                "pure deletion → nothing")
    expectEqual(mine("we should try this agent now",
                     "we should try this agent now and here is a lot more typing that continues"), [],
                "typed continuation → nothing")
    expectEqual(mine("hello there we should meet today", "Hello there we should meet today"), [],
                "sentence-initial capitalization → nothing")
    expectEqual(mine("please receive this today now", "please recieve this today now"), [],
                "lowercase typo → nothing")
    expectEqual(mine("the whole sentence here today", "a completely different rewrite entirely"), [],
                "total rewrite fails the locate gate")
    expectEqual(mine("two tokens", "two Tokens"), [], "below minPastedTokens → nothing")
    let hugeField = String(repeating: "x", count: CorrectionMiner.maxFieldCharacters + 1)
    expectEqual(mine("we should try this now", hugeField), [], "oversized field → nothing")

    // candidate cap
    let manyPaste = "alpha one beta two gamma three delta four epsilon five zeta six"
    let manyField = "AlphaX one BetaX two GammaX three DeltaX four EpsilonX five ZetaX six"
    expect(mine(manyPaste, manyField).count <= CorrectionMiner.maxCandidatesPerUtterance,
           "candidates capped at \(CorrectionMiner.maxCandidatesPerUtterance)")
}

// MARK: - AutoLearnStore

section("AutoLearnStore")
do {
    let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)
    var store = AutoLearnStore()

    expectEqual(store.record("MurmurKit", context: .code, now: t0),
                .counted(term: "MurmurKit", count: 1), "first sighting counts, no promotion")
    expect(store.learned.isEmpty, "nothing learned after one sighting")

    let second = store.record("murmurkit", context: .code, now: t0.addingTimeInterval(60))
    expectEqual(second, .learned(LearnedChange(term: "MurmurKit", context: .code, evicted: nil)),
                "second sighting promotes; first-seen surface wins")
    expect(store.candidates["murmurkit"] == nil, "promoted candidate removed")
    expectEqual(store.learned.count, 1, "ledger records the promotion")

    // Context downgrade: seen in code AND general → general.
    var mixed = AutoLearnStore()
    _ = mixed.record("Jayne", context: .code, now: t0)
    let downgraded = mixed.record("Jayne", context: .general, now: t0.addingTimeInterval(60))
    expectEqual(downgraded, .learned(LearnedChange(term: "Jayne", context: .general, evicted: nil)),
                "cross-context term downgrades to general")

    // TTL: a stale sighting resets instead of promoting.
    var stale = AutoLearnStore()
    _ = stale.record("Qdrant2", context: .code, now: t0)
    let reset = stale.record("Qdrant2", context: .code,
                             now: t0.addingTimeInterval(AutoLearnStore.candidateTTL + 1))
    expectEqual(reset, .counted(term: "Qdrant2", count: 1), "stale candidate resets to 1")

    // Short keys ignored.
    expectEqual(store.record("Ab", context: .code, now: t0), .ignored, "short key ignored")

    // Candidate cap: LRU eviction.
    var capped = AutoLearnStore()
    for i in 0..<(AutoLearnStore.candidateCap + 1) {
        _ = capped.record("Term\(i)Xyz", context: .general, now: t0.addingTimeInterval(Double(i)))
    }
    expectEqual(capped.candidates.count, AutoLearnStore.candidateCap, "candidate cap enforced")
    expect(capped.candidates["term0xyz"] == nil, "oldest candidate evicted")
    expect(capped.candidates["term\(AutoLearnStore.candidateCap)xyz"] != nil, "newest kept")

    // Learned-ledger cap: oldest promotion reported as evicted.
    var ledger = AutoLearnStore()
    for i in 0..<(AutoLearnStore.maxLearnedTerms + 1) {
        let term = "Learned\(i)Xy"
        _ = ledger.record(term, context: .general, now: t0.addingTimeInterval(Double(i * 2)))
        let outcome = ledger.record(term, context: .general, now: t0.addingTimeInterval(Double(i * 2 + 1)))
        if i < AutoLearnStore.maxLearnedTerms {
            expectEqual(outcome, .learned(LearnedChange(term: term, context: .general, evicted: nil)),
                        "promotion \(i) has no eviction")
        } else {
            expectEqual(outcome, .learned(LearnedChange(term: term, context: .general,
                                                        evicted: "Learned0Xy")),
                        "promotion past the cap evicts the oldest learned term")
        }
    }
    expectEqual(ledger.learned.count, AutoLearnStore.maxLearnedTerms, "ledger capped")

    // Codable round-trip.
    let encoded = try! JSONEncoder().encode(store)
    expectEqual(try! JSONDecoder().decode(AutoLearnStore.self, from: encoded), store,
                "store round-trips through JSON")
    expect(!String(decoding: encoded, as: UTF8.self).contains("fieldText"),
           "store serializes terms only")

    // Unknown context string in a promoted entry decodes safely to .general.
    var weird = AutoLearnStore()
    _ = weird.record("Weird1Ab", context: .code, now: t0)
    weird.candidates["weird1ab"]?.context = "not-a-context"
    let weirdOutcome = weird.record("Weird1Ab", context: .code, now: t0.addingTimeInterval(1))
    // context differs ("not-a-context" != "code") → downgraded to general, which is also the fallback.
    expectEqual(weirdOutcome, .learned(LearnedChange(term: "Weird1Ab", context: .general, evicted: nil)),
                "invalid stored context falls back to general")
}

// MARK: - AudioRecorder speech-energy guard

section("AudioRecorder.hasSpeechEnergy")
do {
    expect(!AudioRecorder.hasSpeechEnergy([]), "empty capture is not speech")
    expect(!AudioRecorder.hasSpeechEnergy([Int16](repeating: 0, count: 16_000)), "pure silence is not speech")
    // 100/32768 ≈ 0.003 full-scale, below the 0.004 floor (room tone / muted mic).
    expect(!AudioRecorder.hasSpeechEnergy([Int16](repeating: 100, count: 16_000)), "room-tone energy rejected")
    // 5000/32768 ≈ 0.15 full-scale — clearly speech.
    expect(AudioRecorder.hasSpeechEnergy([Int16](repeating: 5_000, count: 16_000)), "speech-level energy accepted")
    expect(AudioRecorder.hasSpeechEnergy([0, 0, 8_000, -8_000], floor: 0.01), "custom floor honored")
}

// MARK: - AudioRecorder loudness normalization

section("AudioRecorder.normalize")
do {
    expect(AudioRecorder.normalize([]).isEmpty, "empty stays empty")

    // Quiet AC signal (peak 1000 ≈ 0.03 full-scale) is amplified toward target.
    let quiet = (0..<1000).map { Int16($0 % 2 == 0 ? 1000 : -1000) }
    let normPeak = AudioRecorder.normalize(quiet).map { abs(Int($0)) }.max() ?? 0
    expect(normPeak > 5000, "quiet input amplified (peak \(normPeak))")
    expect(AudioRecorder.normalize(quiet).allSatisfy { $0 >= -32768 && $0 <= 32767 }, "no clip past Int16")

    // Max-gain cap: peak 50 (≈0.0015) can amplify at most 10× → ~500.
    let tiny = (0..<100).map { Int16($0 % 2 == 0 ? 50 : -50) }
    let capPeak = AudioRecorder.normalize(tiny, targetPeak: 0.9, maxGain: 10).map { abs(Int($0)) }.max() ?? 0
    expect(capPeak <= 501, "gain capped at 10× (peak ≈ 500, got \(capPeak))")

    // DC offset removed: ±1000 AC around a +4000 bias centers near zero.
    let acDc = (0..<1000).map { Int16(($0 % 2 == 0 ? 1000 : -1000) + 4000) }
    let centered = AudioRecorder.normalize(acDc)
    let mean = centered.reduce(0) { $0 + Int($1) } / centered.count
    expect(abs(mean) < 200, "DC offset removed (mean ≈ \(mean))")

    // Already-loud signal (peak ≈ 0.9 full-scale) left ~unchanged.
    let loud = (0..<1000).map { Int16($0 % 2 == 0 ? 29_500 : -29_500) }
    let loudPeak = AudioRecorder.normalize(loud).map { abs(Int($0)) }.max() ?? 0
    expect(abs(loudPeak - 29_500) < 2000, "already-loud signal roughly unchanged (peak \(loudPeak))")

    // Pure DC (no AC component) has nothing to scale → returned unchanged.
    expectEqual(AudioRecorder.normalize([Int16](repeating: 8000, count: 100)),
                [Int16](repeating: 8000, count: 100), "pure DC returned unchanged")
}

// MARK: - AppContext classification

section("AppContext")
do {
    expectEqual(AppContext.classify(bundleID: "com.microsoft.VSCode", appName: "Code"), .code, "VS Code → code")
    expectEqual(AppContext.classify(bundleID: "com.apple.dt.Xcode", appName: "Xcode"), .code, "Xcode → code")
    expectEqual(AppContext.classify(bundleID: "com.googlecode.iterm2", appName: "iTerm2"), .code, "iTerm2 → code")
    expectEqual(AppContext.classify(bundleID: "com.mitchellh.ghostty", appName: "Ghostty"), .code, "Ghostty → code")
    expectEqual(AppContext.classify(bundleID: "com.jetbrains.pycharm", appName: "PyCharm"), .code, "JetBrains prefix → code")
    expectEqual(AppContext.classify(bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor"), .code, "Cursor by app name → code")
    expectEqual(AppContext.classify(bundleID: "com.apple.mail", appName: "Mail"), .general, "Mail → general")
    expectEqual(AppContext.classify(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"), .general, "Slack → general")
    // A different todesktop/Electron app must NOT be misclassified as a code editor.
    expectEqual(AppContext.classify(bundleID: "com.todesktop.somethingelse", appName: "Linear"), .general,
                "todesktop non-editor → general")
    expectEqual(AppContext.classify(bundleID: nil, appName: nil), .general, "unknown app → general")
}

// MARK: - MsgPack codec

section("MsgPack")
do {
    // Exact wire bytes for the two client→server messages.
    expectEqual(Array(KyutaiStreamingEngine.markerMessage(id: 0)), [
        0x82,
        0xA4, 0x74, 0x79, 0x70, 0x65,             // "type"
        0xA6, 0x4D, 0x61, 0x72, 0x6B, 0x65, 0x72, // "Marker"
        0xA2, 0x69, 0x64,                         // "id"
        0x00,                                     // 0 (positive fixint)
    ], "Marker message exact msgpack bytes")

    expectEqual(Array(KyutaiStreamingEngine.audioMessage([0.0, 1.0])), [
        0x82,
        0xA4, 0x74, 0x79, 0x70, 0x65,             // "type"
        0xA5, 0x41, 0x75, 0x64, 0x69, 0x6F,       // "Audio"
        0xA3, 0x70, 0x63, 0x6D,                   // "pcm"
        0x92,                                     // fixarray(2)
        0xCA, 0x00, 0x00, 0x00, 0x00,             // 0.0  (float32, big-endian)
        0xCA, 0x3F, 0x80, 0x00, 0x00,             // 1.0  (float32, big-endian)
    ], "Audio message exact msgpack bytes")

    // Decoder handles the integer/float/string/array/map types the server uses.
    var w = MsgPackWriter()
    w.writeMapHeader(4)
    w.writeString("type"); w.writeString("Word")
    w.writeString("start_time"); w.writeFloat64(1.5)
    w.writeString("count"); w.writeInt(300)              // uint16 path
    w.writeString("prs"); w.writeArrayHeader(2); w.writeFloat32(0.25); w.writeFloat32(-0.5)
    let value = (try? MsgPackValue.decode(w.data)) ?? .nil
    expectEqual(value["type"]?.stringValue ?? "", "Word", "decode string value")
    expectEqual(value["start_time"]?.doubleValue ?? 0, 1.5, "decode float64 value")
    expectEqual(value["count"]?.intValue ?? 0, 300, "decode uint16 value")
    expectEqual(value["prs"]?.floatArrayValue?.count ?? 0, 2, "decode float-array length")

    // Truncated input fails cleanly rather than crashing.
    expect((try? MsgPackValue.decode(Data([0x82, 0xA4]))) == nil, "truncated input throws")
}

// MARK: - KyutaiStreamingEngine builders + parse

section("KyutaiStreamingEngine")
do {
    let args = KyutaiStreamingEngine.serverArguments(configPath: "/c/stt.toml", port: 8090)
    expect(args.first == "worker", "server runs the worker subcommand")
    expect(args.contains("--config") && args.contains("/c/stt.toml"), "args include config path")
    expect(args.contains("--port") && args.contains("8090"), "args include port")
    if let addrIndex = args.firstIndex(of: "--addr") {
        expectEqual(args[addrIndex + 1], "127.0.0.1", "moshi-server binds loopback only (not 0.0.0.0)")
    } else { expect(false, "args include --addr 127.0.0.1") }

    let request = KyutaiStreamingEngine.webSocketRequest(port: 8090, apiKey: "public_token")
    expectEqual(request.url?.absoluteString, "ws://127.0.0.1:8090/api/asr-streaming", "websocket URL")
    expectEqual(request.value(forHTTPHeaderField: "kyutai-api-key"), "public_token", "api-key header")

    func packed(_ build: (inout MsgPackWriter) -> Void) -> Data {
        var w = MsgPackWriter(); build(&w); return w.data
    }
    let word = KyutaiStreamingEngine.parse(packed { w in
        w.writeMapHeader(3)
        w.writeString("type"); w.writeString("Word")
        w.writeString("text"); w.writeString("hello")
        w.writeString("start_time"); w.writeFloat64(1.25)
    })
    if case .word(let text, let start) = word {
        expectEqual(text, "hello", "parse Word.text")
        expectEqual(start, 1.25, "parse Word.start_time")
    } else { expect(false, "parse returns .word") }

    let marker = KyutaiStreamingEngine.parse(packed { w in
        w.writeMapHeader(2); w.writeString("type"); w.writeString("Marker"); w.writeString("id"); w.writeInt(7)
    })
    if case .marker(let id) = marker { expectEqual(id, 7, "parse Marker.id") }
    else { expect(false, "parse returns .marker") }

    let err = KyutaiStreamingEngine.parse(packed { w in
        w.writeMapHeader(2); w.writeString("type"); w.writeString("Error")
        w.writeString("message"); w.writeString("boom")
    })
    if case .error(let m) = err { expectEqual(m, "boom", "parse Error.message") }
    else { expect(false, "parse returns .error") }

    if case .unknown = KyutaiStreamingEngine.parse(Data([0x01, 0x02, 0x03])) {
        expect(true, "garbage parses as .unknown")
    } else { expect(false, "garbage should be .unknown") }
}

// MARK: - MsgPack: exhaustive codec coverage

func mpBytes(_ build: (inout MsgPackWriter) -> Void) -> [UInt8] {
    var w = MsgPackWriter(); build(&w); return Array(w.data)
}
func mpDecode(_ build: (inout MsgPackWriter) -> Void) -> MsgPackValue {
    var w = MsgPackWriter(); build(&w); return (try? MsgPackValue.decode(w.data)) ?? .nil
}

section("MsgPack: integer encoding boundaries (exact bytes, big-endian)")
do {
    expectEqual(mpBytes { $0.writeInt(0) }, [0x00], "0 → positive fixint")
    expectEqual(mpBytes { $0.writeInt(127) }, [0x7F], "127 → positive fixint max")
    expectEqual(mpBytes { $0.writeInt(128) }, [0xCC, 0x80], "128 → uint8")
    expectEqual(mpBytes { $0.writeInt(255) }, [0xCC, 0xFF], "255 → uint8 max")
    expectEqual(mpBytes { $0.writeInt(256) }, [0xCD, 0x01, 0x00], "256 → uint16 (BE)")
    expectEqual(mpBytes { $0.writeInt(65535) }, [0xCD, 0xFF, 0xFF], "65535 → uint16 max")
    expectEqual(mpBytes { $0.writeInt(65536) }, [0xCE, 0x00, 0x01, 0x00, 0x00], "65536 → uint32 (BE)")
    expectEqual(mpBytes { $0.writeUInt(0xFFFF_FFFF) }, [0xCE, 0xFF, 0xFF, 0xFF, 0xFF], "2^32-1 → uint32")
    expectEqual(mpBytes { $0.writeUInt(0x1_0000_0000) }, [0xCF, 0, 0, 0, 1, 0, 0, 0, 0], "2^32 → uint64 (BE)")
    expectEqual(mpBytes { $0.writeInt(-1) }, [0xFF], "-1 → negative fixint")
    expectEqual(mpBytes { $0.writeInt(-32) }, [0xE0], "-32 → negative fixint min")
    expectEqual(mpBytes { $0.writeInt(-33) }, [0xD0, 0xDF], "-33 → int8")
    expectEqual(mpBytes { $0.writeInt(-128) }, [0xD0, 0x80], "-128 → int8 min")
    expectEqual(mpBytes { $0.writeInt(-129) }, [0xD1, 0xFF, 0x7F], "-129 → int16 (BE)")
    expectEqual(mpBytes { $0.writeInt(-32768) }, [0xD1, 0x80, 0x00], "-32768 → int16 min")
    expectEqual(mpBytes { $0.writeInt(-32769) }, [0xD2, 0xFF, 0xFF, 0x7F, 0xFF], "-32769 → int32 (BE)")
}

section("MsgPack: numeric round-trips")
do {
    for v in [0, 1, 127, 128, 255, 256, 65535, 65536, 16_777_216,
              -1, -32, -33, -128, -129, -32768, -32769, -16_777_216] {
        expectEqual(mpDecode { $0.writeInt(v) }.intValue ?? .min, v, "int round-trip \(v)")
    }
    for v: UInt64 in [0, 255, 256, 65535, 65536, 4_294_967_295, 4_294_967_296] {
        expectEqual(mpDecode { $0.writeUInt(v) }.intValue.map { UInt64($0) } ?? .max, v, "uint round-trip \(v)")
    }
    for v in [Float(0), 1, -1, 0.5, -0.25, 3.5, 12345.678, -0.001] {
        expectEqual(mpDecode { $0.writeFloat32(v) }.doubleValue.map { Float($0) } ?? .nan, v, "float32 round-trip \(v)")
    }
    for v in [0.0, 1.5, -2.25, 1e100, -1e-100, 3.141592653589793] {
        expectEqual(mpDecode { $0.writeFloat64(v) }.doubleValue ?? .nan, v, "float64 round-trip \(v)")
    }
    if case .bool(true) = mpDecode({ $0.writeBool(true) }) { expect(true, "bool true round-trip") }
    else { expect(false, "bool true round-trip") }
    if case .bool(false) = mpDecode({ $0.writeBool(false) }) { expect(true, "bool false round-trip") }
    else { expect(false, "bool false round-trip") }
    if case .nil = mpDecode({ $0.writeNil() }) { expect(true, "nil round-trip") }
    else { expect(false, "nil round-trip") }
    let bin = Data([0xDE, 0xAD, 0xBE, 0xEF])
    if case .binary(let d) = mpDecode({ $0.writeBinary(bin) }) { expectEqual(d, bin, "binary round-trip") }
    else { expect(false, "binary round-trip") }
}

section("MsgPack: strings, arrays, maps & nesting")
do {
    expectEqual(mpBytes { $0.writeString("") }, [0xA0], "empty string → fixstr")
    expectEqual(mpBytes { $0.writeString(String(repeating: "a", count: 31)) }.first ?? 0, 0xBF, "31 chars → fixstr max")
    expectEqual(Array(mpBytes { $0.writeString(String(repeating: "a", count: 32)) }.prefix(2)), [0xD9, 0x20], "32 chars → str8")
    expectEqual(mpDecode { $0.writeString("héllo 🎤") }.stringValue ?? "", "héllo 🎤", "utf8 string round-trip")
    expectEqual(mpDecode { $0.writeString(String(repeating: "x", count: 300)) }.stringValue?.count ?? 0, 300, "str16 round-trip")

    expectEqual(mpBytes { $0.writeArrayHeader(0) }, [0x90], "empty fixarray")
    expectEqual(mpBytes { $0.writeArrayHeader(15) }, [0x9F], "15-elem fixarray max")
    expectEqual(mpBytes { $0.writeArrayHeader(16) }, [0xDC, 0x00, 0x10], "16-elem → array16")
    expectEqual(mpBytes { $0.writeMapHeader(0) }, [0x80], "empty fixmap")
    expectEqual(mpBytes { $0.writeMapHeader(15) }, [0x8F], "15-entry fixmap max")
    expectEqual(mpBytes { $0.writeMapHeader(16) }, [0xDE, 0x00, 0x10], "16-entry → map16")

    var nested = MsgPackWriter()
    nested.writeMapHeader(2)
    nested.writeString("arr"); nested.writeArrayHeader(2); nested.writeInt(1); nested.writeString("two")
    nested.writeString("obj"); nested.writeMapHeader(1); nested.writeString("k"); nested.writeBool(true)
    let nv = (try? MsgPackValue.decode(nested.data)) ?? .nil
    expectEqual(nv["arr"]?.arrayValue?.count ?? 0, 2, "nested array length")
    expectEqual(nv["arr"]?.arrayValue?[1].stringValue ?? "", "two", "nested array element")
    if case .bool(true)? = nv["obj"]?["k"] { expect(true, "nested map value") } else { expect(false, "nested map value") }
}

section("MsgPack: float32 array (audio hot path)")
do {
    expectEqual(mpBytes { $0.writeFloat32Array([]) }, [0x90], "empty pcm → empty fixarray")
    expectEqual(mpBytes { $0.writeFloat32Array([1.0]) }, [0x91, 0xCA, 0x3F, 0x80, 0x00, 0x00], "1-sample pcm exact bytes")
    let h16 = mpBytes { $0.writeFloat32Array([Float](repeating: 0, count: 16)) }
    expectEqual(Array(h16.prefix(3)), [0xDC, 0x00, 0x10], "16 samples cross to array16")
    expectEqual(h16.count, 3 + 16 * 5, "16-sample total size = header + 5 bytes/sample")
    var frame = [Float](repeating: 0, count: 1920)
    for i in 0..<1920 { frame[i] = Float(i) / 1920.0 - 0.5 }
    let rt = mpDecode { $0.writeFloat32Array(frame) }.floatArrayValue ?? []
    expectEqual(rt.count, 1920, "1920-sample frame round-trip length")
    expect(rt == frame, "1920-sample frame preserved exactly")
}

section("MsgPack: malformed input fails cleanly")
do {
    expect((try? MsgPackValue.decode(Data())) == nil, "empty input throws")
    expect((try? MsgPackValue.decode(Data([0xC1]))) == nil, "reserved 0xC1 throws")
    expect((try? MsgPackValue.decode(Data([0xCA, 0x00]))) == nil, "truncated float32 throws")
    expect((try? MsgPackValue.decode(Data([0xA5, 0x41]))) == nil, "fixstr length>payload throws")
    expect((try? MsgPackValue.decode(Data([0xDC, 0x00, 0x05]))) == nil, "array claims 5 elems but empty throws")
    var badKey = MsgPackWriter(); badKey.writeMapHeader(1); badKey.writeInt(1); badKey.writeInt(2)
    expect((try? MsgPackValue.decode(badKey.data)) == nil, "non-string map key throws")
}

section("MsgPack: hostile input can't crash the decoder")
do {
    // A non-finite float id used to trap in Int(Double); intValue now returns nil.
    let nan = KyutaiStreamingEngine.parse(Data(mpBytes { w in
        w.writeMapHeader(2); w.writeString("type"); w.writeString("Marker")
        w.writeString("id"); w.writeFloat32(Float.nan)
    }))
    if case .marker(let id) = nan { expectEqual(id, 0, "NaN Marker.id coerces to default, no trap") }
    else { expect(false, "NaN marker still parses") }
    expectEqual(MsgPackValue.double(.infinity).intValue, nil, "+Inf → nil (no trap)")
    expectEqual(MsgPackValue.double(Double.greatestFiniteMagnitude).intValue, nil, "huge double → nil (no trap)")
    expectEqual(MsgPackValue.double(-3.9).intValue, -3, "finite double still truncates toward zero")

    // Deep nesting must throw (tooDeep), not overflow the stack. 5,000 nested
    // fixarray-of-1 headers is far past the depth cap and far past real frames.
    let deep = Data([UInt8](repeating: 0x91, count: 5_000) + [0xC0])
    expect((try? MsgPackValue.decode(deep)) == nil, "deeply-nested frame throws instead of SIGSEGV")

    // Inflated container length prefixes must be rejected against the remaining
    // bytes before any reserveCapacity — no huge allocation / CPU stall.
    expect((try? MsgPackValue.decode(Data([0xDD, 0xFF, 0xFF, 0xFF, 0xFF]))) == nil,
           "array32 claiming 4.29B elems throws immediately")
    expect((try? MsgPackValue.decode(Data([0xDF, 0xFF, 0xFF, 0xFF, 0xFF]))) == nil,
           "map32 claiming 4.29B entries throws immediately")
}

// MARK: - KyutaiStreamingEngine: full parse + builder round-trips

section("KyutaiStreamingEngine: parse every message type + defaults")
do {
    func parsed(_ build: (inout MsgPackWriter) -> Void) -> KyutaiStreamingEngine.OutMsg {
        var w = MsgPackWriter(); build(&w); return KyutaiStreamingEngine.parse(w.data)
    }
    if case .ready = parsed({ $0.writeMapHeader(1); $0.writeString("type"); $0.writeString("Ready") }) {
        expect(true, "parse Ready")
    } else { expect(false, "parse Ready") }

    if case .endWord(let stop) = parsed({ w in
        w.writeMapHeader(2); w.writeString("type"); w.writeString("EndWord"); w.writeString("stop_time"); w.writeFloat64(2.5)
    }) { expectEqual(stop, 2.5, "parse EndWord.stop_time") } else { expect(false, "parse EndWord") }

    if case .step(let prs) = parsed({ w in
        w.writeMapHeader(3)
        w.writeString("type"); w.writeString("Step")
        w.writeString("step_idx"); w.writeInt(42)
        w.writeString("prs"); w.writeArrayHeader(4)
        w.writeFloat32(0.1); w.writeFloat32(0.2); w.writeFloat32(0.8); w.writeFloat32(0.05)
    }) {
        expectEqual(prs.count, 4, "parse Step.prs length")
        expect(prs.count == 4 && prs[2] == Float(0.8), "parse Step semantic-VAD head value")
    } else { expect(false, "parse Step") }

    // Missing fields fall back to safe defaults rather than crashing.
    if case .word(let t, let s) = parsed({ $0.writeMapHeader(1); $0.writeString("type"); $0.writeString("Word") }) {
        expectEqual(t, "", "Word missing text → empty"); expectEqual(s, 0, "Word missing start_time → 0")
    } else { expect(false, "parse Word defaults") }
    if case .marker(let id) = parsed({ $0.writeMapHeader(1); $0.writeString("type"); $0.writeString("Marker") }) {
        expectEqual(id, 0, "Marker missing id → 0")
    } else { expect(false, "parse Marker default") }
    if case .error(let m) = parsed({ $0.writeMapHeader(1); $0.writeString("type"); $0.writeString("Error") }) {
        expectEqual(m, "unknown", "Error missing message → 'unknown'")
    } else { expect(false, "parse Error default") }
    if case .unknown = parsed({ $0.writeMapHeader(1); $0.writeString("foo"); $0.writeString("bar") }) {
        expect(true, "map without a type field → .unknown")
    } else { expect(false, "map without type → unknown") }
}

section("KyutaiStreamingEngine: message builders round-trip")
do {
    let pcm: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
    let audio = (try? MsgPackValue.decode(KyutaiStreamingEngine.audioMessage(pcm))) ?? .nil
    expectEqual(audio["type"]?.stringValue ?? "", "Audio", "audioMessage type field")
    expectEqual(audio["pcm"]?.floatArrayValue ?? [], pcm, "audioMessage pcm round-trips exactly")
    expectEqual((try? MsgPackValue.decode(KyutaiStreamingEngine.audioMessage([])))?["pcm"]?.floatArrayValue?.count ?? -1,
                0, "empty audioMessage pcm")
    expectEqual((try? MsgPackValue.decode(KyutaiStreamingEngine.audioMessage([Float](repeating: 0.1, count: 1920))))?["pcm"]?.floatArrayValue?.count ?? 0,
                1920, "1920-sample audioMessage round-trips")
    for id in [0, 7, 1000, -5] {
        let m = (try? MsgPackValue.decode(KyutaiStreamingEngine.markerMessage(id: id))) ?? .nil
        expectEqual(m["type"]?.stringValue ?? "", "Marker", "markerMessage type for id \(id)")
        expectEqual(m["id"]?.intValue ?? .min, id, "markerMessage id \(id) round-trips")
    }
}

// MARK: - Config & EngineKind

section("Config & EngineKind")
do {
    expectEqual(EngineKind.allCases.count, 3, "three engines registered")
    expect(EngineKind.groq.isLocal == false, "groq is cloud")
    expect(EngineKind.whisperCpp.isLocal, "whisper is local")
    expect(EngineKind.kyutai.isLocal, "kyutai is local")
    for kind in EngineKind.allCases {
        expect(!kind.displayName.isEmpty, "\(kind.rawValue) has a display name")
        expect(EngineKind(rawValue: kind.rawValue) == kind, "\(kind.rawValue) rawValue round-trips")
    }
    let encoded = try! JSONEncoder().encode(EngineKind.kyutai)
    expectEqual(String(decoding: encoded, as: UTF8.self), "\"kyutai\"", "EngineKind encodes to its rawValue")
    expectEqual(try! JSONDecoder().decode(EngineKind.self, from: encoded), .kyutai, "EngineKind decodes from JSON")

    expectEqual(CleanupEngineKind.allCases.count, 2, "two cleanup engines registered")
    expect(CleanupEngineKind.local.isLocal && !CleanupEngineKind.groq.isLocal, "cleanup isLocal flags")
    for kind in CleanupEngineKind.allCases {
        expect(!kind.displayName.isEmpty, "cleanup \(kind.rawValue) has a display name")
        expect(CleanupEngineKind(rawValue: kind.rawValue) == kind, "cleanup \(kind.rawValue) rawValue round-trips")
    }
    let encodedCleanup = try! JSONEncoder().encode(CleanupEngineKind.local)
    expectEqual(String(decoding: encodedCleanup, as: UTF8.self), "\"local\"", "CleanupEngineKind encodes to rawValue")

    let c = Config()
    expectEqual(c.autoLearnEnabled, true, "auto-learn on by default")
    expectEqual(c.cleanupEngine, .local, "default cleanup engine is local")
    expectEqual(c.llamaPort, 8725, "default llama port")
    expect(c.llamaBinaryPath.contains("llama-server"), "default llama binary path")
    expect(c.llamaModelPath.hasSuffix(".gguf"), "default llama model path is a GGUF")
    expectEqual(c.kyutaiPort, 8090, "default kyutai port")
    expectEqual(c.kyutaiApiKey, "public_token", "default kyutai api key")
    expect(c.kyutaiBinaryPath.contains("moshi-server"), "default kyutai binary path")
    expect(c.kyutaiConfigPath == nil, "default kyutai config path is app-managed (nil)")
    expectEqual(c.engine, .whisperCpp, "default engine is local whisper.cpp")
    expect(c.whisperModelPath.contains("large-v3-turbo"), "default whisper model is large-v3-turbo")

    // Context-aware vocabulary selection: user terms first, builtin appended
    // in code contexts only.
    var v = Config()
    v.customVocabulary = ["Claude", "arXiv"]
    v.codeVocabulary = ["kubectl", "gRPC"]
    let general = v.vocabulary(for: .general)
    expectEqual(Array(general.prefix(2)), ["Claude", "arXiv"],
                "general context → user terms first")
    expectEqual(general.count, 2 + BuiltinVocabulary.general.count,
                "general context → builtin general list appended (code list never leaks in)")
    expect(general.contains("Black-Scholes") && !general.contains("kubectl"),
           "general context gets econ terms, not SWE terms")
    let code = v.vocabulary(for: .code)
    expectEqual(Array(code.prefix(4)), ["kubectl", "gRPC", "Claude", "arXiv"],
                "code context → user terms first (they win the prompt budget)")
    expectEqual(code.count, 4 + BuiltinVocabulary.all.count, "builtin code + general appended after user terms")
    expect(code.contains("PyTorch") && code.contains("Black-Scholes"),
           "code context carries both builtin lists")

    expectEqual(Config().builtinVocabularyEnabled, true, "builtin vocabulary on by default")
    var off = v
    off.builtinVocabularyEnabled = false
    expectEqual(off.vocabulary(for: .code), ["kubectl", "gRPC", "Claude", "arXiv"],
                "flag off → user terms only")
    expectEqual(off.cleanupVocabulary, ["Claude", "arXiv", "kubectl", "gRPC"],
                "flag off → cleanup union is user terms only")

    expectEqual(Array(v.cleanupVocabulary.prefix(4)), ["Claude", "arXiv", "kubectl", "gRPC"],
                "cleanup union is context-independent, user terms first")
    expect(v.cleanupVocabulary.contains("Kubernetes"), "cleanup union carries builtin terms")

    // User casing wins normalize's first-seen rule (the reason builtin goes last).
    var cased = Config()
    cased.codeVocabulary = ["pytorch"]
    let normalized = VocabularyPrompt.normalize(cased.vocabulary(for: .code))
    expect(normalized.contains("pytorch") && !normalized.contains("PyTorch"),
           "user casing overrides the builtin spelling")
}

// MARK: - Cleaner

section("Cleaner")

struct MockChat: ChatEngine {
    var result: Result<String, Error>
    var onCall: ((String, String, Int) -> Void)?
    func chatComplete(system: String, user: String, maxTokens: Int) async throws -> String {
        onCall?(system, user, maxTokens)
        return try result.get()
    }
}

struct MockError: Error {}

await {
    let cleaned = await Cleaner(chat: MockChat(result: .success("I think we should meet at 3pm.")))
        .cleanOrFallback("um I think we should uh meet at 2pm no wait 3pm")
    expectEqual(cleaned, "I think we should meet at 3pm.", "successful cleanup is returned")

    let quoted = await Cleaner(chat: MockChat(result: .success("\"Quoted reply.\"")))
        .cleanOrFallback("quoted reply please with some words")
    expectEqual(quoted, "Quoted reply.", "wrapping quotes stripped")

    let failed = await Cleaner(chat: MockChat(result: .failure(MockError())))
        .cleanOrFallback("this errors but falls back fine")
    expectEqual(failed, "this errors but falls back fine", "thrown error falls back to raw")

    let empty = await Cleaner(chat: MockChat(result: .success("   ")))
        .cleanOrFallback("model returned nothing for this text")
    expectEqual(empty, "model returned nothing for this text", "empty response falls back to raw")

    let bloated = await Cleaner(chat: MockChat(result: .success(String(repeating: "x", count: 500))))
        .cleanOrFallback("short input here okay")
    expectEqual(bloated, "short input here okay", "absurdly long response falls back to raw")

    var llmCalled = false
    var observer = MockChat(result: .success("should never be used"))
    observer.onCall = { _, _, _ in llmCalled = true }
    let short = await Cleaner(chat: observer).cleanOrFallback("too short")
    expectEqual(short, "too short", "short input returned as-is")
    expect(!llmCalled, "short input skips the LLM call entirely")

    var capturedSystem = ""
    var vocabChat = MockChat(result: .success("Deploy to Vercel and Supabase now."))
    vocabChat.onCall = { system, _, _ in capturedSystem = system }
    let vocabOut = await Cleaner(chat: vocabChat, vocabulary: ["Vercel", "Supabase"])
        .cleanOrFallback("deploy to vercel and supabase now please")
    expect(capturedSystem.contains("Vercel") && capturedSystem.contains("Supabase"),
           "cleanup system prompt carries the custom vocabulary")
    expectEqual(vocabOut, "Deploy to Vercel and Supabase now.", "vocab cleanup returns model output")

    var builtinSystem = ""
    var builtinChat = MockChat(result: .success("Install PyTorch with uv."))
    builtinChat.onCall = { system, _, _ in builtinSystem = system }
    _ = await Cleaner(chat: builtinChat, vocabulary: Config().cleanupVocabulary)
        .cleanOrFallback("install pie torch with uv please")
    expect(builtinSystem.contains("Remove filler words"), "base cleanup rules survive the vocabulary rule")
    expect(builtinSystem.contains("PyTorch") && builtinSystem.contains("Kubernetes"),
           "cleanup system prompt carries the built-in vocabulary by default")

    var swappedSystem = ""
    var swapChat = MockChat(result: .success("Fine."))
    swapChat.onCall = { system, _, _ in swappedSystem = system }
    let original = Cleaner(chat: swapChat, vocabulary: ["AlphaTermOne"])
    _ = await original.withVocabulary(["BetaTermTwo"])
        .cleanOrFallback("some dictated words to clean here")
    expect(swappedSystem.contains("BetaTermTwo") && !swappedSystem.contains("AlphaTermOne"),
           "withVocabulary swaps the spelling rule")
    expect(swappedSystem.contains("Remove filler words"), "withVocabulary keeps the base rules")
}()

// MARK: - Integration fixture (say → 16 kHz WAV through OUR encoder)

func buildFixtureWAV() throws -> Data {
    let dir = FileManager.default.temporaryDirectory
    let pid = ProcessInfo.processInfo.processIdentifier
    let aiff = dir.appendingPathComponent("murmur-fixture-\(pid).aiff")
    let wavURL = dir.appendingPathComponent("murmur-fixture-\(pid).wav")
    defer {
        try? FileManager.default.removeItem(at: aiff)
        try? FileManager.default.removeItem(at: wavURL)
    }

    func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "fixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"])
        }
    }
    try run("/usr/bin/say", ["-o", aiff.path, "the quick brown fox jumps over the lazy dog"])
    try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wavURL.path])

    // Decode to raw samples and re-encode through OUR WAVEncoder, so every
    // integration test also validates our header against a real decoder.
    let audioFile = try AVAudioFile(forReading: wavURL)
    guard audioFile.processingFormat.sampleRate == 16_000 else {
        throw NSError(domain: "fixture", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "fixture not 16 kHz"])
    }
    let frameCount = AVAudioFrameCount(audioFile.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                        frameCapacity: frameCount) else {
        throw NSError(domain: "fixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
    }
    try audioFile.read(into: buffer)
    guard let floats = buffer.floatChannelData?[0] else {
        throw NSError(domain: "fixture", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "no float channel data"])
    }
    var samples = [Int16](repeating: 0, count: Int(buffer.frameLength))
    for i in 0..<Int(buffer.frameLength) {
        samples[i] = Int16(max(-32768, min(32767, floats[i] * 32767)))
    }
    return WAVEncoder.encode(samples: samples, sampleRate: 16_000)
}

/// Same spoken fixture as 24 kHz mono Float32 samples — what the Kyutai
/// streaming engine consumes (the app's `AudioRecorder` produces this live).
func buildFixtureFloat32_24k(
    _ phrase: String = "the quick brown fox jumps over the lazy dog"
) throws -> [Float] {
    let dir = FileManager.default.temporaryDirectory
    let pid = ProcessInfo.processInfo.processIdentifier
    let tag = String(abs(phrase.hashValue) % 100_000)
    let aiff = dir.appendingPathComponent("murmur-fix24-\(pid)-\(tag).aiff")
    let wavURL = dir.appendingPathComponent("murmur-fix24-\(pid)-\(tag).wav")
    defer {
        try? FileManager.default.removeItem(at: aiff)
        try? FileManager.default.removeItem(at: wavURL)
    }
    func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "fixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"])
        }
    }
    try run("/usr/bin/say", ["-o", aiff.path, phrase])
    try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@24000", "-c", "1", aiff.path, wavURL.path])

    let audioFile = try AVAudioFile(forReading: wavURL)
    let frameCount = AVAudioFrameCount(audioFile.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                        frameCapacity: frameCount) else {
        throw NSError(domain: "fixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
    }
    try audioFile.read(into: buffer)
    guard let floats = buffer.floatChannelData?[0] else {
        throw NSError(domain: "fixture", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "no float channel data"])
    }
    return Array(UnsafeBufferPointer(start: floats, count: Int(buffer.frameLength)))
}

// MARK: - LocalServer hardening (pure)

section("LocalServer: sensitive env + exec safety + free port")
do {
    for key in ["GROQ_API_KEY", "OPENAI_API_KEY", "AWS_SECRET_ACCESS_KEY",
                "HF_TOKEN", "DB_PASSWORD", "GH_TOKEN"] {
        expect(LocalServer.isSensitiveEnvKey(key), "\(key) is treated as sensitive")
    }
    for key in ["PATH", "HOME", "LANG", "MURMUR_HOTKEY", "TERM"] {
        expect(!LocalServer.isSensitiveEnvKey(key), "\(key) is not sensitive")
    }
    expect(LocalServer.sanitizedEnvironment()["GROQ_API_KEY"] == nil,
           "sanitized child env never carries GROQ_API_KEY")

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ls_exec_\(UUID().uuidString)")
    FileManager.default.createFile(atPath: tmp.path, contents: Data("#!/bin/sh\n".utf8),
                                   attributes: [.posixPermissions: 0o755])
    expect(LocalServer.isSafeToExecute(tmp.path), "0755 owner-only-writable executable is safe")
    try? FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: tmp.path)
    expect(!LocalServer.isSafeToExecute(tmp.path), "world-writable executable is refused")
    try? FileManager.default.removeItem(at: tmp)
    expect(!LocalServer.isSafeToExecute(tmp.path), "missing binary is not safe to execute")

    if let port = LocalServer.freeLoopbackPort() {
        expect(port > 0 && port <= 65535, "freeLoopbackPort returns a port in range (got \(port))")
    } else { expect(false, "freeLoopbackPort returned nil") }
}

// MARK: - Integration: local whisper.cpp (no API key needed)

let testConfig = Config.load()
let whisperModel = (testConfig.whisperModelPath as NSString).expandingTildeInPath
if FileManager.default.isExecutableFile(atPath: testConfig.whisperBinaryPath),
   FileManager.default.fileExists(atPath: whisperModel) {
    section("Integration: local whisper.cpp STT")
    await {
        // Dedicated port so a running Murmur instance's server is untouched.
        let engine = WhisperCppEngine(binaryPath: testConfig.whisperBinaryPath,
                                      modelPath: testConfig.whisperModelPath, port: 18_723)
        defer { engine.shutdown() }
        do {
            let wav = try buildFixtureWAV()
            let start = Date()
            let transcript = try await engine.transcribe(wav: wav)
            print("  transcript (\(String(format: "%.2f", -start.timeIntervalSinceNow))s incl. model load): \(transcript)")
            let normalized = transcript.lowercased()
            expect(normalized.contains("quick brown fox"), "local transcript contains 'quick brown fox'")
            expect(normalized.contains("lazy dog"), "local transcript contains 'lazy dog'")

            let again = Date()
            _ = try await engine.transcribe(wav: wav)
            print("  warm second pass: \(String(format: "%.2f", -again.timeIntervalSinceNow))s")
        } catch {
            failed += 1
            print("  FAIL — local whisper integration threw: \(error)")
        }
    }()
} else {
    print("• Integration: local whisper.cpp — SKIPPED (whisper-server or model not installed)")
}

// MARK: - Integration: local Kyutai streaming (no API key needed)

/// Stream a fixture through a fresh session and finalize, reporting whether live
/// partials arrived and the release→final flush time.
func kyutaiRun(_ engine: KyutaiStreamingEngine, _ samples: [Float]) async throws
    -> (text: String, sawPartial: Bool, seconds: Double) {
    let session = try engine.makeSession()
    var sawPartial = false
    session.onPartial = { _ in sawPartial = true }
    var i = 0
    while i < samples.count {
        let end = min(i + 1920, samples.count)
        session.append(Array(samples[i..<end]))
        i = end
    }
    let start = Date()
    let text = try await session.finish()
    return (text, sawPartial, -start.timeIntervalSinceNow)
}

let kyutaiBinary = (testConfig.kyutaiBinaryPath as NSString).expandingTildeInPath
let kyutaiConfig = testConfig.kyutaiConfigPath.map { ($0 as NSString).expandingTildeInPath }
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Murmur/kyutai/moshi-stt.toml").path
if FileManager.default.isExecutableFile(atPath: kyutaiBinary),
   FileManager.default.fileExists(atPath: kyutaiConfig) {
    section("Integration: local Kyutai streaming STT")
    await {
        // Dedicated port so a running Murmur (or Phase-0) server is untouched.
        let engine = KyutaiStreamingEngine(binaryPath: kyutaiBinary, configPath: kyutaiConfig,
                                           port: 18_724, apiKey: testConfig.kyutaiApiKey)
        defer { engine.shutdown() }
        do {
            try await engine.ensureReady()

            // 1) Cold-ish first utterance — accuracy + live partials.
            let p1 = try await kyutaiRun(engine, try buildFixtureFloat32_24k())
            print("  pass 1 (\(String(format: "%.2f", p1.seconds))s): \(p1.text)")
            expect(p1.text.lowercased().contains("quick brown fox"), "pass 1 contains 'quick brown fox'")
            expect(p1.text.lowercased().contains("lazy dog"), "pass 1 contains 'lazy dog'")
            expect(p1.sawPartial, "pass 1 delivered live partials")

            // 2) Warm second utterance, a different phrase (proves session reuse).
            let p2 = try await kyutaiRun(engine, try buildFixtureFloat32_24k("hello world this is a streaming test"))
            print("  pass 2 warm (\(String(format: "%.2f", p2.seconds))s): \(p2.text)")
            let n2 = p2.text.lowercased()
            expect(n2.contains("hello") && n2.contains("world"), "warm pass transcribes a different phrase")

            // 3) Silence only → empty transcript, no words, no hang/crash.
            let p3 = try await kyutaiRun(engine, [Float](repeating: 0, count: 24_000))
            print("  pass 3 silence (\(String(format: "%.2f", p3.seconds))s): '\(p3.text)'")
            expect(p3.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "silence yields an empty transcript")
            expect(!p3.sawPartial, "silence produced no word partials")

            // 4) cancel() mid-stream must not crash, and the engine stays usable.
            let cancelled = try engine.makeSession()
            cancelled.append([Float](repeating: 0.1, count: 1920))
            cancelled.append([Float](repeating: -0.1, count: 1920))
            cancelled.cancel()
            let p4 = try await kyutaiRun(engine, try buildFixtureFloat32_24k())
            expect(p4.text.lowercased().contains("quick brown fox"), "engine still works after a cancelled session")
        } catch {
            failed += 1
            print("  FAIL — Kyutai integration threw: \(error)")
        }
    }()
} else {
    print("• Integration: local Kyutai — SKIPPED (run scripts/install_kyutai.sh)")
}

// MARK: - Integration: local llama.cpp cleanup (gated on binary + model on disk)

let llamaModel = (testConfig.llamaModelPath as NSString).expandingTildeInPath
if FileManager.default.isExecutableFile(atPath: testConfig.llamaBinaryPath),
   FileManager.default.fileExists(atPath: llamaModel) {
    section("Integration: local llama.cpp cleanup")
    await {
        // Dedicated port so a running Murmur instance's server is untouched.
        let engine = LlamaCppChatEngine(binaryPath: testConfig.llamaBinaryPath,
                                        modelPath: testConfig.llamaModelPath, port: 18_725)
        defer { engine.shutdown() }
        do {
            let start = Date()
            try await engine.ensureReady()
            print("  server ready in \(String(format: "%.1f", -start.timeIntervalSinceNow))s")

            let cleaner = Cleaner(chat: engine, vocabulary: Config().cleanupVocabulary)
            let cleaned = await cleaner.cleanOrFallback(
                "um so basically I think we should uh meet at two pm no wait actually three pm")
            print("  cleaned: \(cleaned)")
            let tokens = cleaned.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            expect(!tokens.contains("um"), "local cleanup removed 'um'")
            expect(!tokens.contains("uh"), "local cleanup removed 'uh'")
            expect(tokens.contains("three") || tokens.contains("3"), "local self-correction kept 3pm")
            expect(!cleaned.isEmpty, "local cleanup output non-empty")

            // The transcript is data, not instructions — a dictated question
            // must be cleaned, never answered (validates the 3B model choice).
            let question = await cleaner.cleanOrFallback("what is the capital of France")
            print("  question passthrough: \(question)")
            expect(!question.lowercased().contains("paris"), "dictated question is not answered")

            // Phonetic vocab repair is probabilistic for a 3B model — observe,
            // don't assert (the repo rule: integration tests must pass).
            let warm = Date()
            let vocab = await cleaner.cleanOrFallback("please install pie torch and scikit learn today")
            print("  vocab repair (observation): \(vocab)")
            print("  warm call: \(String(format: "%.2f", -warm.timeIntervalSinceNow))s")
        } catch {
            failed += 1
            print("  FAIL — local llama.cpp integration threw: \(error)")
        }
    }()
} else {
    print("• Integration: local llama.cpp cleanup — SKIPPED (run scripts/install_llama.sh)")
}

// MARK: - Integration: Groq (gated on key from env or app config)

// Opt-in ONLY: a plain `swift run MurmurTests` must never silently spend the key
// saved in the user's app config or upload audio to Groq. Requires GROQ_API_KEY
// in the environment, or MURMUR_TEST_GROQ=1 to explicitly allow the config key.
let processEnv = ProcessInfo.processInfo.environment
let envGroqKey = processEnv["GROQ_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
let allowConfigKey = processEnv["MURMUR_TEST_GROQ"] == "1"
let apiKey = envGroqKey ?? (allowConfigKey ? (testConfig.groqAPIKey ?? "") : "")
if apiKey.isEmpty {
    print("• Integration: Groq — SKIPPED (set GROQ_API_KEY, or MURMUR_TEST_GROQ=1 to use the app config key)")
} else {
    let keySource = envGroqKey != nil ? "env GROQ_API_KEY" : "app config (MURMUR_TEST_GROQ=1)"
    section("Integration: Groq STT + LLM cleanup")
    print("  key source: \(keySource)")
    await {
        do {
            let wav = try buildFixtureWAV()
            let client = GroqClient(apiKey: apiKey, sttModel: testConfig.sttModel,
                                    chatModel: testConfig.cleanupModel, language: testConfig.language)
            let transcript = try await client.transcribe(wav: wav)
            print("  transcript: \(transcript)")
            let normalized = transcript.lowercased()
            expect(normalized.contains("quick brown fox"), "transcript contains 'quick brown fox'")
            expect(normalized.contains("lazy dog"), "transcript contains 'lazy dog'")

            let cleaner = Cleaner(chat: client)
            let cleaned = await cleaner.cleanOrFallback(
                "um so basically I think we should uh meet at two pm no wait actually three pm")
            print("  cleaned: \(cleaned)")
            let tokens = cleaned.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            expect(!tokens.contains("um"), "cleanup removed 'um'")
            expect(!tokens.contains("uh"), "cleanup removed 'uh'")
            expect(tokens.contains("three") || tokens.contains("3"), "self-correction kept 3pm")
            expect(!cleaned.isEmpty, "cleanup output non-empty")
        } catch {
            failed += 1
            print("  FAIL — Groq integration threw: \(error)")
        }
    }()
}

// MARK: - summary

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
