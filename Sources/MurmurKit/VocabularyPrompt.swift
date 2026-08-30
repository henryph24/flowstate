import Foundation

/// Builds prompt-biasing strings from the user's custom vocabulary (names,
/// jargon, acronyms). Whisper steers its spelling toward terms that appear in
/// its `prompt`, and the cleanup LLM uses the same list as a spelling guide.
///
/// Two deliberate choices, both backed by the prompting guidance:
///  - Sentence-style framing ("…may include these terms: …") biases more
///    reliably than a bare comma list.
///  - Whisper only honors roughly the final 224 prompt tokens, so the term
///    list is capped to a conservative character budget that leaves room for
///    the framing sentence.
public enum VocabularyPrompt {
    /// ~224 Whisper tokens ≈ 800 chars; we stay well under so the framing
    /// sentence is never the part that gets truncated away.
    static let maxTermCharacters = 600

    /// The cleanup LLM's system prompt has no 224-token ceiling, so the full
    /// built-in list plus a large personal list fit (~1750 + ~1050 chars on
    /// this machine). Still bounded so a huge config can't inflate every
    /// cleanup request or drown the 8B model's core rules. ~3000 chars ≈ 750
    /// tokens, ~4× the base prompt.
    static let maxCleanupTermCharacters = 3000

    /// Trimmed, case-insensitively de-duplicated, order-preserving term list.
    public static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            if seen.insert(term.lowercased()).inserted { out.append(term) }
        }
        return out
    }

    /// Sentence-style initial prompt for Whisper's `/inference`, or nil when
    /// there's nothing to bias.
    public static func whisperPrompt(_ terms: [String]) -> String? {
        guard let list = cappedList(terms, budget: maxTermCharacters) else { return nil }
        return "The transcript may include these terms: \(list)."
    }

    /// A rule appended to the cleanup system prompt so the LLM preserves and
    /// fixes near-miss spellings of the user's terms. Nil when empty.
    public static func cleanupRule(_ terms: [String]) -> String? {
        guard let list = cappedList(terms, budget: maxCleanupTermCharacters) else { return nil }
        return "- Preserve and correctly spell these terms when they appear; "
            + "fix obvious near-miss misspellings of them: \(list)."
    }

    /// Normalized terms joined with ", ", truncated to the character budget.
    /// Nil when no terms survive normalization.
    private static func cappedList(_ terms: [String], budget: Int) -> String? {
        let normalized = normalize(terms)
        guard !normalized.isEmpty else { return nil }
        var included: [String] = []
        var length = 0
        for term in normalized {
            let added = term.count + (included.isEmpty ? 0 : 2) // ", " separator
            if !included.isEmpty, length + added > budget { break }
            included.append(term)
            length += added
        }
        return included.joined(separator: ", ")
    }
}
