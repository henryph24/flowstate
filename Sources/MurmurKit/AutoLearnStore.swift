import Foundation

/// What `applyLearnedTerm` must do when a candidate is promoted.
public struct LearnedChange: Equatable {
    public let term: String
    public let context: AppContext
    /// Oldest auto-learned term to drop from the config arrays, or nil. Caps
    /// learned terms so they can never push the builtin prompt tiers off the
    /// 600-char Whisper budget; hand-added terms are never evicted.
    public let evicted: String?

    public init(term: String, context: AppContext, evicted: String?) {
        self.term = term
        self.context = context
        self.evicted = evicted
    }
}

public enum AutoLearnOutcome: Equatable {
    case ignored
    case counted(term: String, count: Int)
    case learned(LearnedChange)
}

/// Pure candidate ledger for auto-learn. Persisted as a sidecar
/// (~/.config/murmur/autolearn.json) so per-utterance churn never rewrites the
/// hand-curated config; only single TERMS are ever stored, never field text.
public struct AutoLearnStore: Codable, Equatable {
    public struct Candidate: Codable, Equatable {
        public var term: String    // first-seen surface ("MurmurKit")
        public var count: Int
        public var context: String // AppContext.rawValue
        public var lastSeen: Date
    }

    public struct Learned: Codable, Equatable {
        public var term: String
        public var context: String
        public var at: Date
    }

    public static let promotionThreshold = 2
    public static let candidateCap = 200
    public static let maxLearnedTerms = 50
    public static let candidateTTL: TimeInterval = 30 * 24 * 3600

    public var version = 1
    public var candidates: [String: Candidate] = [:] // key = TranscriptCorrector.key(term)
    public var learned: [Learned] = []               // promotion order, oldest first

    public init() {}

    public mutating func record(_ term: String, context: AppContext, now: Date) -> AutoLearnOutcome {
        let key = TranscriptCorrector.key(term)
        guard key.count >= TranscriptCorrector.minKeyLength else { return .ignored }

        if var entry = candidates[key] {
            if now.timeIntervalSince(entry.lastSeen) > Self.candidateTTL {
                // A sighting from months ago shouldn't promote today.
                entry.count = 1
                entry.lastSeen = now
                candidates[key] = entry
                return .counted(term: entry.term, count: 1)
            }
            entry.count += 1
            entry.lastSeen = now
            // First-seen surface wins (mirrors VocabularyPrompt.normalize);
            // a term corrected in both a code app and elsewhere is general
            // vocabulary — customVocabulary is active everywhere.
            if entry.context != context.rawValue { entry.context = AppContext.general.rawValue }
            if entry.count >= Self.promotionThreshold {
                candidates[key] = nil
                learned.append(Learned(term: entry.term, context: entry.context, at: now))
                var evicted: String?
                if learned.count > Self.maxLearnedTerms {
                    evicted = learned.removeFirst().term
                }
                let learnedContext = AppContext(rawValue: entry.context) ?? .general
                return .learned(LearnedChange(term: entry.term, context: learnedContext,
                                              evicted: evicted))
            }
            candidates[key] = entry
            return .counted(term: entry.term, count: entry.count)
        }

        candidates[key] = Candidate(term: term, count: 1, context: context.rawValue, lastSeen: now)
        while candidates.count > Self.candidateCap {
            // LRU eviction; key tie-break keeps it deterministic.
            if let victim = candidates.min(by: { ($0.value.lastSeen, $0.key) < ($1.value.lastSeen, $1.key) }) {
                candidates[victim.key] = nil
            }
        }
        return .counted(term: term, count: 1)
    }
}

public enum AutoLearnStoreFile {
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/murmur/autolearn.json")
    }

    public static func load() -> AutoLearnStore {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(AutoLearnStore.self, from: data) else {
            return AutoLearnStore()
        }
        return store
    }

    public static func save(_ store: AutoLearnStore) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
