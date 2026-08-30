import Foundation

/// Coordinator for learn-from-corrections: after Murmur pastes, wait, read the
/// SAME app's focused field back once, mine user corrections, and promote
/// recurring terms into the config vocabulary. Main-thread by construction
/// (owned and driven by AppController); all OS touchpoints are injected so the
/// mining core stays pure and testable.
public final class AutoLearn {
    public static let defaultReadBackDelay: TimeInterval = 25

    /// Dev-loop override, same convention as MURMUR_HOTKEY / MURMUR_ENGINE.
    public static var readBackDelay: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["MURMUR_AUTOLEARN_DELAY"],
           let value = TimeInterval(raw), value > 0 { return value }
        return defaultReadBackDelay
    }

    private struct Pending {
        let pasted: String
        let pid: pid_t
        let context: AppContext
        let element: AnyObject? // focused field captured at paste time (same-field guard)
    }

    private let enabled: Bool
    private let isKnownWord: (String) -> Bool
    private let captureElement: (pid_t) -> AnyObject?
    private let readField: (pid_t, AnyObject?) -> String?
    private let frontmostPID: () -> pid_t?
    private let saveStore: (AutoLearnStore) -> Void
    private let loadStore: () -> AutoLearnStore

    /// Full effective vocabulary keys (user + builtin) — set by AppController.
    public var existingVocabularyKeys: () -> Set<String> = { [] }
    /// Fired on promotion; AppController appends to config and refreshes.
    public var onLearn: ((LearnedChange) -> Void)?

    private var pending: Pending?
    private var timer: Timer?
    // Lazy so a disabled kill switch never touches autolearn.json at all.
    private lazy var store: AutoLearnStore = loadStore()

    public init(enabled: Bool,
                isKnownWord: @escaping (String) -> Bool,
                captureElement: @escaping (pid_t) -> AnyObject?,
                readField: @escaping (pid_t, AnyObject?) -> String?,
                frontmostPID: @escaping () -> pid_t?,
                loadStore: @escaping () -> AutoLearnStore,
                saveStore: @escaping (AutoLearnStore) -> Void) {
        self.enabled = enabled
        self.isKnownWord = isKnownWord
        self.captureElement = captureElement
        self.readField = readField
        self.frontmostPID = frontmostPID
        self.loadStore = loadStore
        self.saveStore = saveStore
    }

    /// Called after a `.pasted` outcome. Fires any pending read-back first
    /// (its field is about to be superseded), then arms a fresh one-shot.
    public func schedule(pasted: String, pid: pid_t, context: AppContext) {
        guard enabled else { return }
        flushPending()
        pending = Pending(pasted: pasted, pid: pid, context: context,
                          element: captureElement(pid))
        timer = Timer.scheduledTimer(withTimeInterval: Self.readBackDelay,
                                     repeats: false) { [weak self] _ in
            self?.flushPending()
        }
    }

    /// Read back now — the field is about to change (next dictation) or the
    /// timer fired. One read per paste, ever; every guard is a silent drop.
    public func flushPending() {
        timer?.invalidate()
        timer = nil
        guard let job = pending else { return }
        pending = nil
        guard enabled,
              frontmostPID() == job.pid,
              let fieldText = readField(job.pid, job.element),
              !fieldText.isEmpty else { return }

        let found = CorrectionMiner.candidates(pasted: job.pasted,
                                               fieldText: fieldText,
                                               isKnownWord: isKnownWord,
                                               existingVocabularyKeys: existingVocabularyKeys())
        guard !found.isEmpty else { return }
        for term in found {
            switch store.record(term, context: job.context, now: Date()) {
            case .ignored:
                continue
            case .counted(let term, let count):
                Log.info("auto-learn: candidate \"\(term)\" (\(count)/\(AutoLearnStore.promotionThreshold))")
            case .learned(let change):
                Log.info("auto-learn: learned \"\(change.term)\""
                    + (change.evicted.map { " (evicted \"\($0)\")" } ?? ""))
                onLearn?(change)
            }
        }
        saveStore(store)
    }

    /// Quit path: drop any pending read-back without touching AX.
    public func cancel() {
        timer?.invalidate()
        timer = nil
        pending = nil
    }
}
