import Foundation

/// Deterministic vocabulary repair: rewrites transcript spans whose
/// letters+digits exactly match a vocabulary term's, fixing only casing,
/// hyphenation, spacing, and in-term punctuation ("scikit learn" →
/// "scikit-learn", "pytorch" → "PyTorch"). Runs on every utterance — before
/// and after the cleanup LLM, and alone when no LLM is available — so term
/// repair works fully offline.
///
/// Contract: exact-normalized-key matching only. No edit distance, no
/// phonetics — a deterministic layer that can be wrong is worse than one with
/// gaps ("pie torch" and "Jason"→JSON are the cleanup LLM's job). Guards:
///  - Keys shorter than 4 chars never enter the index (C++, jq, uv, S3).
///  - Single-token rewrites only for terms that cannot be ordinary English
///    words by construction (see `allowsSingleTokenRewrite`): internal capital
///    or in-term punctuation/space, plus at least one lowercase letter. So
///    "old rag", "at the helm", "two pandas" are never touched.
///  - Never down-cases: a surface starting uppercase is left alone when the
///    term starts lowercase ("Vector database is fast." keeps its capital).
///  - Multi-token spans must be contiguous words — punctuation at an inner
///    boundary ("scikit, learn", "next. JS") refuses the match.
public struct TranscriptCorrector {
    /// Keys shorter than this never enter the index.
    public static let minKeyLength = 4
    /// Longest token span a single term may match ("chain of thought" → 3).
    public static let maxSpan = 4

    /// normalized key → canonical term; first-seen wins so user terms
    /// (ordered ahead of the builtin list) keep their casing.
    private let index: [String: String]

    /// `aliases` are curated spoken forms whose normalized key DIFFERS from
    /// their replacement's ("pie torch" → PyTorch, "cube control" → kubectl) —
    /// forms whose key already equals the term's are matched without an alias.
    /// Terms win key collisions over aliases; earlier aliases win over later
    /// (user aliases are ordered first). An alias replacement is canonicalized
    /// through the term index so a user's own casing still wins.
    public init(terms: [String], aliases: [(spoken: String, replacement: String)] = []) {
        var index: [String: String] = [:]
        for term in VocabularyPrompt.normalize(terms) {
            let key = Self.key(term)
            guard key.count >= Self.minKeyLength, index[key] == nil else { continue }
            index[key] = term
        }
        for alias in aliases {
            let key = Self.key(alias.spoken)
            guard key.count >= Self.minKeyLength, index[key] == nil else { continue }
            index[key] = index[Self.key(alias.replacement)] ?? alias.replacement
        }
        self.index = index
    }

    public var isEmpty: Bool { index.isEmpty }

    /// Lowercased letters+digits only: "Next.js" → "nextjs", "KV cache" → "kvcache".
    static func key<S: StringProtocol>(_ s: S) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A lone token may be rewritten only to a term that cannot be an ordinary
    /// English word: it must contain a lowercase letter AND either in-term
    /// punctuation/space (Next.js, scikit-learn, Hugging Face) or an internal
    /// capital (PyTorch, gRPC). All-caps terms (RAG, JSON) and Capitalized-only
    /// terms (Rust, Helm, Playwright) are rejected — their lowercase forms are
    /// real words. All-lowercase terms are rejected too (a rewrite would be a
    /// no-op, and this guarantees sentence-initial words are never down-cased).
    public static func allowsSingleTokenRewrite(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        guard letters.contains(where: \.isLowercase) else { return false }
        if term.contains(where: { !$0.isLetter && !$0.isNumber }) { return true }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    public func correct(_ text: String) -> String {
        guard !index.isEmpty, !text.isEmpty else { return text }

        // Whitespace-delimited tokens with their alphanumeric core. Tokens
        // with no core (standalone punctuation) stay in the list as span
        // blockers so "scikit , learn" cannot match across the comma.
        struct Token {
            let core: Range<String.Index>?
            let leadAlnum: Bool   // token starts with its core (no leading punct)
            let trailAlnum: Bool  // token ends with its core (no trailing punct)
        }
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            var coreStart = i
            while coreStart < j, !(text[coreStart].isLetter || text[coreStart].isNumber) {
                coreStart = text.index(after: coreStart)
            }
            var coreEnd = j
            while coreEnd > coreStart {
                let prev = text.index(before: coreEnd)
                if text[prev].isLetter || text[prev].isNumber { break }
                coreEnd = prev
            }
            if coreStart < coreEnd {
                tokens.append(Token(core: coreStart..<coreEnd,
                                    leadAlnum: coreStart == i, trailAlnum: coreEnd == j))
            } else {
                tokens.append(Token(core: nil, leadAlnum: false, trailAlnum: false))
            }
            i = j
        }

        var result = ""
        var cursor = text.startIndex
        var t = 0
        while t < tokens.count {
            guard tokens[t].core != nil else { t += 1; continue }
            var advanced = false
            let maxSpanHere = min(Self.maxSpan, tokens.count - t)
            for span in stride(from: maxSpanHere, through: 1, by: -1) {
                let slice = Array(tokens[t..<(t + span)])
                guard slice.allSatisfy({ $0.core != nil }) else { continue }
                if span >= 2 {
                    // Inner boundaries must be bare word edges.
                    let contiguous = slice.enumerated().allSatisfy { offset, tok in
                        (offset == 0 || tok.leadAlnum) && (offset == span - 1 || tok.trailAlnum)
                    }
                    guard contiguous else { continue }
                }
                let candidateKey = slice.map { Self.key(text[$0.core!]) }.joined()
                guard candidateKey.count >= Self.minKeyLength,
                      let term = index[candidateKey] else { continue }
                if span == 1, !Self.allowsSingleTokenRewrite(term) { continue }

                let surfaceRange = slice.first!.core!.lowerBound..<slice.last!.core!.upperBound
                let surface = String(text[surfaceRange])
                if surface == term {
                    // Already canonical — consume the span so no smaller
                    // rewrite fires inside it. Text is copied verbatim.
                    t += span
                    advanced = true
                    break
                }
                if let surfaceFirst = surface.first(where: \.isLetter),
                   let termFirst = term.first(where: \.isLetter),
                   surfaceFirst.isUppercase, termFirst.isLowercase {
                    continue // never down-case (sentence-initial capitals)
                }

                result += text[cursor..<surfaceRange.lowerBound]
                result += term
                cursor = surfaceRange.upperBound
                t += span
                advanced = true
                break
            }
            if !advanced { t += 1 }
        }
        result += text[cursor...]
        return result
    }
}
