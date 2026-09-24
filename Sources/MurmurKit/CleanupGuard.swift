import Foundation

/// Holds the cleanup LLM to the edits dictation cleanup exists for. The
/// model's output is aligned word by word against the transcript it was
/// given, and only these edits survive:
///  - deleting filler sounds (um, uh, er, hmm, …), and "you know" / "I mean" /
///    "like" when the transcript sets them off with commas on both sides;
///  - deleting stutters (a word or phrase said again right away);
///  - deleting a short self-corrected span that ends in a correction cue
///    ("at 2, no wait, 3" → "at 3"; "to Bob, sorry, I mean to Alice" → "to Alice");
///  - re-spacing or re-hyphenating the same characters ("fine tune" → "fine-tune");
///  - replacing a short span with a vocabulary term it resembles ("pie torch" → "PyTorch").
/// Every other change (a dropped clause, a paraphrase, an added word, a changed
/// number, an answer to a dictated question) is reverted to the transcript's
/// own words, so the speaker's sentences come through as spoken. Measured on a
/// 44-case fidelity corpus, unguarded Llama-3.2-3B rewrote 10 of 22 sentences
/// that needed no edit (36 words lost), answered "Tell me a joke about
/// databases" with a joke, and obeyed a dictated "reply with the word banana".
///
/// Pure and deterministic; the output is exactly the model's text whenever
/// the model made only allowed edits.
public enum CleanupGuard {
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "mmm", "mhm",
    ]
    /// Elongated spellings ("hmmm", "ummm") collapse to one of these.
    static let collapsedFillers: Set<String> = ["um", "uh", "uhm", "hm", "ah", "eh", "mhm"]
    /// Deletable only with commas on both sides ("I was, you know, thinking"):
    /// otherwise they are usually content ("Do you know…", "I like it").
    static let bracketedFillers: [[String]] = [["you", "know"], ["i", "mean"], ["like"]]
    /// Cues that mark a self-correction even in an unpunctuated transcript.
    static let strongCues: [[String]] = [
        ["no", "wait"], ["scratch", "that"], ["i", "meant"], ["or", "rather"], ["correction"],
    ]
    /// Everyday words that mark a correction only after a pause (a comma or a
    /// period before them): "Monday, actually, make that Tuesday" but never
    /// "please make that call" or "there is no way".
    static let weakCues: [[String]] = [["wait"], ["sorry"], ["i", "mean"], ["actually"], ["make", "that"], ["no"]]
    /// A self-correction retracts a short span ("2", "to Bob", "with PyTorch").
    static let maxCorrectedWords = 4
    /// Repeated for emphasis, not stutters: "much, much faster", "very, very".
    static let intensifiers: Set<String> = [
        "very", "much", "really", "so", "far", "way", "too", "many", "super", "quite", "extremely",
    ]
    static let maxSubstitutionWords = 4
    /// Letter similarity a span needs to be swapped for a vocabulary term. One
    /// word must be close ("pedantic" → Pydantic 0.88, but not "database" →
    /// Supabase 0.63); a split phrase can be looser ("numb pie" → NumPy 0.57).
    static let minSingleWordSimilarity = 0.7
    static let minMultiWordSimilarity = 0.55
    /// Alignment is O(n·m): ~2,000 words a side (13+ minutes of speech, past
    /// `maxRecordSeconds`) before the guard stops aligning and keeps the
    /// transcript as spoken.
    static let maxAlignmentCells = 4_000_000
    /// Number words align with digits, so a correction the model wrote as
    /// "3 pm" still lines up with a spoken "three pm". ("one" is left out:
    /// "no one" must never become "no 1".)
    static let numberWords: [String: String] = [
        "zero": "0", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
    ]

    /// Lookup keys for `reconcile`'s vocabulary check; build once per term list.
    public static func vocabularyKeys(_ terms: [String]) -> Set<String> {
        Set(VocabularyPrompt.normalize(terms).map(TranscriptCorrector.key))
    }

    /// `vocabularyKeys` comes from `vocabularyKeys(_:)`.
    public static func reconcile(transcript: String, cleaned: String,
                                 vocabularyKeys: Set<String>) -> String {
        let input = tokenize(transcript)
        let output = tokenize(cleaned)
        let a = input.indices.filter { !input[$0].key.isEmpty }
        let b = output.indices.filter { !output[$0].key.isEmpty }
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= maxAlignmentCells else { return transcript }
        let text = Text(input: input, output: output, a: a, b: b, vocabularyKeys: vocabularyKeys)

        // Repeated words make the alignment ambiguous. Pairing each with its
        // LAST occurrence keeps the later half of a stutter or correction;
        // pairing with the FIRST keeps "you" in "when you, you know, finish".
        // Whichever reverts less wins.
        let x = a.map { input[$0].value }, y = b.map { output[$0].value }
        let late = plan(align(x, y), text)
        guard late.reverts > 0 else { return cleaned }
        let early = plan(alignEarly(x, y), text)
        guard early.reverts > 0 else { return cleaned }
        return rebuild(early.reverts < late.reverts ? early : late, text, transcript: transcript)
    }

    // MARK: tokens and alignment

    struct Token {
        let surface: String
        let key: String   // letters+digits, lowercased; "" for punctuation-only
        let value: String // what must match: case-folded, edge punctuation off, number words as digits
    }

    struct Text {
        let input: [Token]
        let output: [Token]
        let a: [Int] // word positions in `input`
        let b: [Int] // word positions in `output`
        let vocabularyKeys: Set<String>
    }

    static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).map { raw in
            let surface = String(raw)
            let key = TranscriptCorrector.key(surface)
            let bare = surface.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                .trimmingCharacters(in: edgePunctuation)
            return Token(surface: surface, key: key, value: numberWords[bare] ?? bare)
        }
    }

    /// Stripped from word edges before comparing: sentence punctuation and
    /// quotes only. Symbols that carry value stay ("2.5", "5%", "-5", "C++").
    static let edgePunctuation = CharacterSet(
        charactersIn: ".,;:!?\"'()[]{}\u{201C}\u{201D}\u{2018}\u{2019}\u{2026}\u{2014}\u{2013}")

    enum Op: Equatable {
        case match(Int, Int), delete(Int), insert(Int)
        var isMatch: Bool { if case .match = self { return true } else { return false } }
    }

    /// Longest-common-subsequence alignment, backtracked from the END so a
    /// repeated word pairs with its LAST occurrence.
    static func align(_ x: [String], _ y: [String]) -> [Op] {
        let n = x.count, m = y.count
        let width = m + 1
        var dp = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                dp[i * width + j] = x[i - 1] == y[j - 1]
                    ? dp[(i - 1) * width + j - 1] + 1
                    : max(dp[(i - 1) * width + j], dp[i * width + j - 1])
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, x[i - 1] == y[j - 1] {
                ops.append(.match(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, j == 0 || dp[(i - 1) * width + j] >= dp[i * width + j - 1] {
                ops.append(.delete(i - 1)); i -= 1
            } else {
                ops.append(.insert(j - 1)); j -= 1
            }
        }
        return ops.reversed()
    }

    /// The same alignment, pairing repeated words with their FIRST occurrence.
    static func alignEarly(_ x: [String], _ y: [String]) -> [Op] {
        let n = x.count, m = y.count
        return align(x.reversed(), y.reversed()).reversed().map { op in
            switch op {
            case .match(let i, let j): return .match(n - 1 - i, m - 1 - j)
            case .delete(let i): return .delete(n - 1 - i)
            case .insert(let j): return .insert(m - 1 - j)
            }
        }
    }

    // MARK: deciding each word's fate

    enum Fate {
        case matched(Int)  // output token index
        case restored      // transcript word the model dropped without cause
        case deleted       // an allowed deletion
        case substitutedHead(outputs: [Int], last: Int) // output token indices; last transcript index
        case substitutedTail
    }

    struct Plan {
        var fate: [Fate]
        var boundary: Set<Int> // transcript indices beside dropped model words
        var reverts: Int       // restored words + dropped model words
    }

    static func plan(_ ops: [Op], _ t: Text) -> Plan {
        var fate = [Fate](repeating: .restored, count: t.input.count)
        for case .match(let ai, let bi) in ops { fate[t.a[ai]] = .matched(t.b[bi]) }
        var boundary = Set<Int>()
        var dropped = 0
        var k = 0
        var lastMatched = -1 // position in `a` of the latest aligned word
        while k < ops.count {
            if case .match(let ai, _) = ops[k] {
                lastMatched = ai
                k += 1
                continue
            }
            var deleted: [Int] = [] // positions in `a`
            var inserted: [Int] = [] // positions in `b`
            while k < ops.count, !ops[k].isMatch {
                if case .delete(let ai) = ops[k] { deleted.append(ai) }
                if case .insert(let bi) = ops[k] { inserted.append(bi) }
                k += 1
            }
            let matchAfter = k < ops.count
            if !inserted.isEmpty, let s = bestSubstitution(deleted, inserted, t) {
                let span = Array(deleted[s])
                fate[t.a[span[0]]] = .substitutedHead(outputs: inserted.map { t.b[$0] }, last: t.a[span.last!])
                for ai in span.dropFirst() { fate[t.a[ai]] = .substitutedTail }
                judgeDeletion(Array(deleted[..<s.lowerBound]), keptAfter: true, t, &fate)
                judgeDeletion(Array(deleted[s.upperBound...]), keptAfter: matchAfter, t, &fate)
            } else {
                judgeDeletion(deleted, keptAfter: matchAfter, t, &fate)
                if !inserted.isEmpty {
                    // Dropped model words: the aligned words on both sides of
                    // the gap were written around them.
                    dropped += inserted.count
                    if lastMatched >= 0 { boundary.insert(t.a[lastMatched]) }
                    let after = lastMatched + deleted.count + 1
                    if after < t.a.count { boundary.insert(t.a[after]) }
                }
            }
        }
        let restored = t.a.filter { if case .restored = fate[$0] { return true } else { return false } }.count
        return Plan(fate: fate, boundary: boundary, reverts: restored + dropped)
    }

    /// Marks the allowed deletions in a run of dropped transcript words
    /// (consecutive positions in `a`); everything else stays `.restored`.
    static func judgeDeletion(_ run: [Int], keptAfter: Bool, _ t: Text, _ fate: inout [Fate]) {
        guard let first = run.first, let last = run.last else { return }
        let range = first...last
        let wholeRun = isCorrection(range, keptAfter: keptAfter, t)
            || isRepeat(range, t, fate)
            || isBracketedFiller(range, t)
        let tail = wholeRun ? nil : correctionTail(range, keptAfter: keptAfter, t, fate)
        for ai in run where wholeRun || tail?.contains(ai) == true
            || isFiller(ai, t) || isStutter(ai, run: range, t, fate) {
            fate[t.a[ai]] = .deleted
        }
    }

    /// A self-correction at the end of a longer dropped run ("Ship it to all
    /// customers on Friday, no wait," → only "Friday, no wait," goes). Strong
    /// cues only: inside a longer drop, "but, I mean," is a filler after a
    /// clause, not a correction. Prefers the tail starting on the word the
    /// speaker restarted with ("with PyTorch, no wait, | with MLX"), else the
    /// shortest.
    static func correctionTail(_ run: ClosedRange<Int>, keptAfter: Bool, _ t: Text,
                               _ fate: [Fate]) -> ClosedRange<Int>? {
        guard run.count > 1 else { return nil }
        let restart = (run.upperBound + 1..<t.a.count).first { !isFiller($0, t) }
            .flatMap { j -> String? in
                if case .matched = fate[t.a[j]] { return t.input[t.a[j]].key } else { return nil }
            }
        var shortest: ClosedRange<Int>?
        for start in stride(from: run.upperBound - 1, to: run.lowerBound, by: -1) {
            let tail = start...run.upperBound
            guard isCorrection(tail, keptAfter: keptAfter, strongOnly: true, t) else { continue }
            if shortest == nil { shortest = tail }
            if let word = restart, t.input[t.a[start]].key == word { return tail }
        }
        return shortest
    }

    /// A filler sound, unless it is really a unit ("10 mm", "5 Ah") or an
    /// acronym ("the ER").
    static func isFiller(_ ai: Int, _ t: Text) -> Bool {
        let token = t.input[t.a[ai]]
        guard fillers.contains(token.key) || collapsedFillers.contains(collapsed(token.key)) else { return false }
        let letters = token.surface.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return false }
        if ai > 0, t.input[t.a[ai - 1]].key.allSatisfy(\.isNumber) { return false }
        return true
    }

    /// "hmmm" → "hm", "uhhh" → "uh".
    static func collapsed(_ key: String) -> String {
        var out = ""
        for ch in key where out.last != ch { out.append(ch) }
        return out
    }

    /// The same word said again beside it, fillers aside ("the, uh, the
    /// link"), with the copy the model KEPT: dropping every copy would lose the
    /// word. Never across a sentence end ("I said no. No one came").
    static func isStutter(_ ai: Int, run: ClosedRange<Int>, _ t: Text, _ fate: [Fate]) -> Bool {
        let key = t.input[t.a[ai]].key
        guard !intensifiers.contains(key) else { return false }
        for step in [-1, 1] {
            var j = ai
            while true {
                if step == 1, endsSentence(t.input[t.a[j]].surface) { break }
                j += step
                guard j >= 0, j < t.a.count else { break }
                if step == -1, endsSentence(t.input[t.a[j]].surface) { break }
                if isFiller(j, t) { continue }
                guard t.input[t.a[j]].key == key else { break }
                if run.contains(j) { continue } // another dropped copy: follow the chain
                if case .matched = fate[t.a[j]] { return true }
                break
            }
        }
        return false
    }

    /// The run is the phrase kept right after (or before) it, said one or more
    /// extra times: "can we, can we, can we move". Fillers inside are ignored.
    static func isRepeat(_ run: ClosedRange<Int>, _ t: Text, _ fate: [Fate]) -> Bool {
        let core = run.filter { !isFiller($0, t) }.map { t.input[t.a[$0]].key }
        guard !core.isEmpty, !core.allSatisfy(intensifiers.contains) else { return false }
        func kept(_ positions: [Int]) -> [String]? {
            let words = positions.filter { !isFiller($0, t) }
            guard words.allSatisfy({ if case .matched = fate[t.a[$0]] { return true } else { return false } })
            else { return nil }
            return words.map { t.input[t.a[$0]].key }
        }
        for period in 1...core.count where core.count % period == 0 {
            let unit = Array(core[..<period])
            guard core.indices.allSatisfy({ core[$0] == unit[$0 % period] }) else { continue }
            if !endsSentence(t.input[t.a[run.upperBound]].surface) {
                var after: [Int] = []
                var j = run.upperBound + 1
                while after.filter({ !isFiller($0, t) }).count < period, j < t.a.count { after.append(j); j += 1 }
                if kept(after) == unit { return true }
            }
            if run.lowerBound > 0, !endsSentence(t.input[t.a[run.lowerBound - 1]].surface) {
                var before: [Int] = []
                var j = run.lowerBound - 1
                while before.filter({ !isFiller($0, t) }).count < period, j >= 0 { before.insert(j, at: 0); j -= 1 }
                if kept(before) == unit { return true }
            }
        }
        return false
    }

    /// "It's, um, like, fine" / "I was, you know, thinking": commas on both
    /// sides of the phrase (fillers inside ignored).
    static func isBracketedFiller(_ run: ClosedRange<Int>, _ t: Text) -> Bool {
        let words = run.filter { !isFiller($0, t) }
        guard let last = words.last, bracketedFillers.contains(words.map { t.input[t.a[$0]].key }),
              t.input[t.a[last]].surface.hasSuffix(","), run.lowerBound > 0 else { return false }
        return t.input[t.a[run.lowerBound - 1]].surface.hasSuffix(",")
    }

    /// "<≤4 corrected words> <cue>" with the replacement still to come, e.g.
    /// "2, no wait," or "to Bob, sorry, I mean". The run must END in the cue.
    static func isCorrection(_ run: ClosedRange<Int>, keptAfter: Bool, strongOnly: Bool = false,
                             _ t: Text) -> Bool {
        let words = run.filter { !isFiller($0, t) }
        let keys = words.map { t.input[t.a[$0]].key }
        guard keptAfter, keys.count >= 2 else { return false }
        var covered = [Bool](repeating: false, count: keys.count)
        var strongStarts: [Int] = []
        for start in keys.indices {
            for (cues, strong) in [(strongCues, true), (weakCues, false)] {
                for cue in cues where start + cue.count <= keys.count
                    && Array(keys[start..<start + cue.count]) == cue {
                    for i in start..<start + cue.count { covered[i] = true }
                    if strong { strongStarts.append(start) }
                }
            }
        }
        guard covered.last == true else { return false }
        var blockStart = keys.count
        while blockStart > 0, covered[blockStart - 1] { blockStart -= 1 }
        guard blockStart >= 1, blockStart <= maxCorrectedWords else { return false }
        let corrected = words[..<blockStart].map { t.input[t.a[$0]].surface }
        // A question or a finished sentence before the cue, or a cue that ends
        // a sentence ("Cancel it? No."), is an answer, not a correction.
        guard !corrected.contains(where: { $0.hasSuffix("?") || $0.hasSuffix("!") }),
              !corrected.dropLast().contains(where: endsSentence),
              !endsSentence(t.input[t.a[words.last!]].surface) else { return false }
        let strong = strongStarts.contains { $0 >= blockStart }
        let paused = trailingPunctuation(corrected.last!).contains { ",;:.-\u{2014}\u{2013}".contains($0) }
        return strong || (paused && !strongOnly)
    }

    /// The span of `deleted` (positions in `a`) the model's `inserted` words
    /// may replace: the same characters re-spaced or re-hyphenated, or a
    /// vocabulary term resembling the span.
    static func bestSubstitution(_ deleted: [Int], _ inserted: [Int], _ t: Text) -> Range<Int>? {
        guard !deleted.isEmpty, inserted.count <= maxSubstitutionWords else { return nil }
        let targetKey = inserted.map { t.output[t.b[$0]].key }.joined()
        let targetShape = shape(inserted.map { t.output[t.b[$0]].value })
        let termSurface = inserted.map { t.output[t.b[$0]].surface }.joined(separator: " ")
            .trimmingCharacters(in: edgePunctuation)
        let isTerm = t.vocabularyKeys.contains(targetKey)
        var best: (range: Range<Int>, score: Double)?
        for start in deleted.indices {
            for end in start + 1...deleted.count {
                let span = Array(deleted[start..<end])
                let words = span.filter { !isFiller($0, t) }
                guard !words.isEmpty, words.count <= maxSubstitutionWords else { continue }
                let score: Double
                if shape(span.map { t.input[t.a[$0]].value }) == targetShape {
                    score = 2 // identical characters beat any resemblance
                } else if isTerm {
                    let key = words.map { t.input[t.a[$0]].key }.joined()
                    score = similarity(key, targetKey)
                    if words.count == 1 {
                        // A short lone word ("help", "to") may only become a
                        // term no English word could be ("gRPC", not "Helm").
                        guard score >= minSingleWordSimilarity, key.count >= 5
                                || TranscriptCorrector.allowsSingleTokenRewrite(termSurface) else { continue }
                    } else {
                        guard score >= minMultiWordSimilarity else { continue }
                    }
                } else {
                    continue
                }
                if best == nil || score > best!.score { best = (start..<end, score) }
            }
        }
        return best?.range
    }

    /// Words joined with in-word hyphens dropped: "fine tune" and "fine-tune"
    /// share a shape; "-5" keeps its sign.
    static func shape(_ values: [String]) -> String {
        let chars = Array(values.joined())
        return String(chars.indices.filter { i in
            !(chars[i] == "-" && i > 0 && i + 1 < chars.count
              && (chars[i - 1].isLetter || chars[i - 1].isNumber)
              && (chars[i + 1].isLetter || chars[i + 1].isNumber))
        }.map { chars[$0] })
    }

    /// 1 − (character edit distance ÷ longer length).
    static func similarity(_ s: String, _ t: String) -> Double {
        let x = Array(s), y = Array(t)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: rebuilding the text

    enum PieceKind { case matched(Int), restored, substituted }

    struct Piece {
        let surface: String
        let first: Int          // first transcript index covered
        let input: Int          // last transcript index covered
        let kind: PieceKind
        let deletedBefore: Int? // start of an allowed deletion right before this piece

        var isRestored: Bool { if case .restored = kind { return true } else { return false } }
    }

    static func rebuild(_ plan: Plan, _ t: Text, transcript: String) -> String {
        let input = t.input, output = t.output
        var pieces: [Piece] = []
        var pendingDeletion: Int? // first index of the deletion run awaiting its neighbor
        var lastWasKept = false
        for i in input.indices {
            switch plan.fate[i] {
            case .matched(let bi):
                pieces.append(Piece(surface: output[bi].surface, first: i, input: i, kind: .matched(bi),
                                    deletedBefore: pendingDeletion))
            case .restored:
                if input[i].key.isEmpty, !lastWasKept { continue } // dangling punctuation of a deletion
                pieces.append(Piece(surface: input[i].surface, first: i, input: i, kind: .restored,
                                    deletedBefore: pendingDeletion))
            case .substitutedHead(let outputs, let last):
                pieces.append(Piece(surface: outputs.map { output[$0].surface }.joined(separator: " "),
                                    first: i, input: last, kind: .substituted, deletedBefore: pendingDeletion))
            case .substitutedTail:
                continue
            case .deleted:
                if pendingDeletion == nil { pendingDeletion = i }
                lastWasKept = false
                continue
            }
            pendingDeletion = nil
            lastWasKept = true
        }
        let trailingDeletion = pendingDeletion
        guard !pieces.isEmpty else { return transcript }

        // Words beside a reverted edit take the transcript's spelling and
        // punctuation: the model's there was written for a sentence that no
        // longer exists ("…to Thursday." before a restored "because…" clause).
        var surfaces: [String] = []
        var own: [Bool] = [] // true where the transcript's surface is used
        for p in pieces.indices {
            let piece = pieces[p]
            let nextRestored = p + 1 < pieces.count && pieces[p + 1].isRestored
            switch piece.kind {
            case .restored:
                surfaces.append(piece.surface); own.append(true)
            case .matched:
                let beside = plan.boundary.contains(piece.input) || nextRestored
                    || (p > 0 && pieces[p - 1].isRestored)
                surfaces.append(beside ? input[piece.input].surface : piece.surface); own.append(beside)
            case .substituted:
                // Keep the transcript's punctuation after a swapped-in term.
                surfaces.append(nextRestored ? stripTrailingPunctuation(piece.surface)
                                + trailingPunctuation(input[piece.input].surface) : piece.surface)
                own.append(false)
            }
        }

        // Seams where an allowed deletion meets transcript-spelled words.
        for p in pieces.indices {
            guard let start = pieces[p].deletedBefore else { continue }
            if p > 0, own[p - 1] {
                if case .matched(let bi) = pieces[p - 1].kind {
                    // The model saw the deletion: its punctuation there stands
                    // ("apples, um, oranges" keeps the list comma).
                    surfaces[p - 1] = stripTrailingPunctuation(surfaces[p - 1])
                        + trailingPunctuation(output[bi].surface)
                } else if surfaces[p - 1].hasSuffix(","),
                          let last = lastWordIndex(input, from: start, before: pieces[p].first),
                          input[last].surface.hasSuffix(",") {
                    surfaces[p - 1].removeLast() // "which is, um, way" → "which is way"
                }
            }
            if own[p], p == 0 || endsSentence(surfaces[p - 1]) {
                surfaces[p] = sentenceCased(surfaces[p], t.vocabularyKeys) // "Hmm, let me" → "Let me"
            }
        }
        // The model capitalized the opening word: keep that where the
        // transcript's own (lowercase) first word came back.
        if own[0], output[t.b[0]].surface.first(where: \.isLetter)?.isUppercase == true {
            surfaces[0] = sentenceCased(surfaces[0], t.vocabularyKeys)
        }
        // Keep the text's closing punctuation: the transcript's (after a
        // trailing deletion, "I think, um." → "I think.") or else the model's.
        if let lastIdx = surfaces.indices.last, own[lastIdx], !endsSentence(surfaces[lastIdx]) {
            var terminal = ""
            if let start = trailingDeletion, let last = lastWordIndex(input, from: start, before: input.count) {
                terminal = trailingPunctuation(input[last].surface).filter { ".?!".contains($0) }
            }
            if terminal.isEmpty {
                terminal = trailingPunctuation(output[t.b.last!].surface).filter { ".?!".contains($0) }
            }
            if !terminal.isEmpty {
                surfaces[lastIdx] = stripTrailingPunctuation(surfaces[lastIdx]) + terminal
            }
        }
        return surfaces.joined(separator: " ")
    }

    // MARK: helpers

    private static func lastWordIndex(_ input: [Token], from start: Int, before end: Int) -> Int? {
        var i = end - 1
        while i >= start {
            if !input[i].key.isEmpty { return i }
            i -= 1
        }
        return nil
    }

    static func trailingPunctuation(_ s: String) -> String {
        String(s.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }

    static func stripTrailingPunctuation(_ s: String) -> String {
        String(s.dropLast(trailingPunctuation(s).count))
    }

    static func endsSentence(_ s: String) -> Bool {
        trailingPunctuation(s).contains { ".?!".contains($0) }
    }

    /// Capitalizes an all-lowercase ordinary word opening a sentence; leaves
    /// vocabulary terms ("kubectl") and mixed-case words ("iPhone") alone.
    static func sentenceCased(_ s: String, _ vocabularyKeys: Set<String>) -> String {
        guard let idx = s.firstIndex(where: \.isLetter), !s.contains(where: \.isUppercase),
              !vocabularyKeys.contains(TranscriptCorrector.key(s)) else { return s }
        return s.replacingCharacters(in: idx...idx, with: s[idx].uppercased())
    }
}
