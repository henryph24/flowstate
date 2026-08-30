import Foundation

/// Pure core of auto-learn: given the text Murmur pasted and the field's text
/// read back later, find terms the USER corrected — a similar-looking unknown
/// token replacing what was transcribed. Every gate is tuned so false
/// negatives are free (learn nothing) and false positives are rare; the ≥2
/// recurrence requirement lives upstream in `AutoLearnStore`.
public enum CorrectionMiner {
    public static let minPastedTokens = 3
    public static let maxPastedTokens = 400
    public static let maxFieldCharacters = 100_000
    public static let windowPad = 8
    public static let maxAnchors = 3
    public static let maxAnchorOccurrences = 8
    public static let maxWindows = 8
    public static let minMatchRatio = 0.6
    public static let minMatchedTokens = 2
    public static let maxBlockTokens = 3
    public static let maxTermCharacters = 40
    public static let maxCandidatesPerUtterance = 3

    public struct Token: Equatable {
        public let core: String            // edge punctuation trimmed, possessive stripped
        public let key: String             // TranscriptCorrector.key(core)
        public let isSentenceInitial: Bool // first, or preceded by . ! ? : ; or a newline
    }

    public enum Op: Equatable {
        case match(pasted: Int, field: Int) // equal keys; surfaces may differ
        case delete(pasted: Int)
        case insert(field: Int)
    }

    // MARK: tokenization

    public static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var sentenceInitial = true // a new line starts a sentence
            for chunk in line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace) {
                var core = chunk[...]
                while let first = core.first, !first.isLetter, !first.isNumber {
                    core = core.dropFirst()
                }
                while let last = core.last, !last.isLetter, !last.isNumber {
                    core = core.dropLast()
                }
                // Possessive: "MurmurKit's" → "MurmurKit" so both sides align.
                for suffix in ["'s", "\u{2019}s"] where core.hasSuffix(suffix) {
                    core = core.dropLast(suffix.count)
                }
                let endsSentence = chunk.last.map { ".!?:;".contains($0) } ?? false
                if !core.isEmpty {
                    tokens.append(Token(core: String(core),
                                        key: TranscriptCorrector.key(core),
                                        isSentenceInitial: sentenceInitial))
                    sentenceInitial = endsSentence
                } else if endsSentence {
                    sentenceInitial = true // standalone punctuation ends a sentence
                }
            }
        }
        return tokens
    }

    // MARK: similarity

    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    public static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// Similar to any individual old key OR their concatenation (the concat is
    /// what makes "murmur kit" → MurmurKit work); a shared ≥4-char prefix with
    /// a small length delta covers suffix extensions.
    public static func isSimilar(new: String, old: [String]) -> Bool {
        var comparisons = old
        if old.count > 1 { comparisons.append(old.joined()) }
        return comparisons.contains { o in
            let n = max(new.count, o.count)
            let budget = n <= 4 ? 1 : n <= 8 ? 2 : 3
            if editDistance(new, o) <= budget { return true }
            return sharedPrefixLength(new, o) >= 4 && abs(new.count - o.count) <= 4
        }
    }

    /// Structural "could be a real term" gate. Rejects ALL-CAPS (their
    /// lowercase forms are words, and the corrector can't use them anyway),
    /// all-lowercase (typos; corrector-inert), and sentence-initial
    /// Capitalized words (macOS autocapitalization). Accepts digits, in-term
    /// punctuation, internal capitals, and mid-sentence proper nouns (names).
    public static func isTermLike(_ core: String, sentenceInitial: Bool) -> Bool {
        let letters = core.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        if core.contains(where: \.isNumber) { return true } // GPT-4, K3s — before the ALL-CAPS gate
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return false }
        if core.dropFirst().contains(where: { !$0.isLetter && !$0.isNumber }) { return true }
        if letters.dropFirst().contains(where: \.isUppercase) { return true }
        if letters.first!.isUppercase, !sentenceInitial { return true }
        return false
    }

    // MARK: alignment

    /// LCS on keys with backtrack → edit script.
    public static func align(_ pasted: [Token], _ field: [Token]) -> [Op] {
        let n = pasted.count, m = field.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = pasted[i].key == field[j].key
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if pasted[i].key == field[j].key {
                ops.append(.match(pasted: i, field: j)); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(pasted: i)); i += 1
            } else {
                ops.append(.insert(field: j)); j += 1
            }
        }
        while i < n { ops.append(.delete(pasted: i)); i += 1 }
        while j < m { ops.append(.insert(field: j)); j += 1 }
        return ops
    }

    /// Anchor-then-score window search: raw LCS of a short paste against a
    /// huge document happily matches scattered stopwords, so windows are
    /// proposed only around RARE pasted tokens, then verified by a ≥60%
    /// key-survival gate. nil = couldn't confidently find the paste → learn
    /// nothing (false negatives are free).
    public static func locate(pasted: [Token], in field: [Token]) -> Range<Int>? {
        guard pasted.count >= minPastedTokens, pasted.count <= maxPastedTokens else { return nil }

        var positions: [String: [Int]] = [:]
        for (j, token) in field.enumerated() { positions[token.key, default: []].append(j) }

        var pastedKeyCounts: [String: Int] = [:]
        for token in pasted { pastedKeyCounts[token.key, default: 0] += 1 }

        var anchors: [(pastedIndex: Int, occurrences: [Int])] = []
        for (i, token) in pasted.enumerated() {
            guard token.key.count >= TranscriptCorrector.minKeyLength,
                  pastedKeyCounts[token.key] == 1,
                  let occurrences = positions[token.key],
                  occurrences.count <= maxAnchorOccurrences else { continue }
            anchors.append((i, occurrences))
        }
        anchors.sort { ($0.occurrences.count, $0.pastedIndex) < ($1.occurrences.count, $1.pastedIndex) }

        var starts: [Int] = []
        for anchor in anchors.prefix(maxAnchors) {
            for j in anchor.occurrences {
                starts.append(max(0, j - anchor.pastedIndex - windowPad))
            }
        }
        if starts.isEmpty {
            guard field.count <= pasted.count + 2 * windowPad else { return nil }
            starts = [0]
        }
        var seen = Set<Int>()
        starts = starts.filter { seen.insert($0).inserted }
        starts = Array(starts.prefix(maxWindows))

        let windowLength = pasted.count + 2 * windowPad
        var best: (start: Int, matched: Int)?
        for start in starts {
            let end = min(field.count, start + windowLength)
            guard start < end else { continue }
            let matched = align(pasted, Array(field[start..<end]))
                .filter { if case .match = $0 { return true } else { return false } }.count
            if best == nil || matched > best!.matched
                || (matched == best!.matched && start < best!.start) {
                best = (start, matched)
            }
        }
        guard let found = best,
              found.matched >= max(minMatchedTokens,
                                   Int(ceil(minMatchRatio * Double(pasted.count)))) else { return nil }
        return found.start..<min(field.count, found.start + windowLength)
    }

    // MARK: vocabulary identity

    /// Keys in `TranscriptCorrector`'s normalization — punctuation-insensitive,
    /// so "nextjs" is never learned alongside a known "Next.js".
    public static func vocabularyKeys(_ terms: [String]) -> Set<String> {
        Set(terms.map { TranscriptCorrector.key($0) })
    }

    // MARK: pipeline

    public static func candidates(pasted: String,
                                  fieldText: String,
                                  isKnownWord: (String) -> Bool,
                                  existingVocabularyKeys: Set<String>) -> [String] {
        guard fieldText.count <= maxFieldCharacters, pasted != fieldText else { return [] }
        let pastedTokens = tokenize(pasted)
        let fieldTokens = tokenize(fieldText)
        guard let windowRange = locate(pasted: pastedTokens, in: fieldTokens) else { return [] }
        let window = Array(fieldTokens[windowRange])
        let ops = align(pastedTokens, window)

        var found: [String] = []
        var foundKeys = Set<String>()
        func consider(_ token: Token, old: [Token]) {
            guard token.key.count >= TranscriptCorrector.minKeyLength,
                  token.core.count <= maxTermCharacters,
                  isSimilar(new: token.key, old: old.map(\.key)),
                  !isKnownWord(token.core),
                  !existingVocabularyKeys.contains(token.key),
                  isTermLike(token.core, sentenceInitial: token.isSentenceInitial),
                  foundKeys.insert(token.key).inserted else { return }
            found.append(token.core)
        }

        var blockOld: [Token] = []
        var blockNew: [Token] = []
        func flushBlock() {
            defer { blockOld = []; blockNew = [] }
            guard !blockOld.isEmpty, !blockNew.isEmpty,
                  blockOld.count <= maxBlockTokens, blockNew.count <= maxBlockTokens else { return }
            for token in blockNew { consider(token, old: blockOld) }
        }
        for op in ops {
            switch op {
            case .match(let p, let f):
                flushBlock()
                // Key-equal but surface-different: a casing/punctuation edit.
                if pastedTokens[p].core != window[f].core {
                    consider(window[f], old: [pastedTokens[p]])
                }
            case .delete(let p):
                blockOld.append(pastedTokens[p])
            case .insert(let f):
                blockNew.append(window[f])
            }
        }
        flushBlock()
        return Array(found.prefix(maxCandidatesPerUtterance))
    }
}
