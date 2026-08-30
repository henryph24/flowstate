import AppKit

/// "Is this an ordinary word?" — the gate that keeps auto-learn from adopting
/// typos. NSSpellChecker-backed (AppleSpell XPC), main-thread like the rest of
/// AppController's world, memoized because the XPC round trip isn't free.
/// Deliberately kept OUT of unit-test assert paths — headless CLI behavior is
/// machine/locale-dependent; tests inject a fixed word set instead.
public enum SystemDictionary {
    private static var cache: [String: Bool] = [:]

    public static func isKnownWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return true } // fail safe = "known" = don't learn
        if let hit = cache[word] { return hit }
        func spellsClean(_ s: String) -> Bool {
            NSSpellChecker.shared.checkSpelling(of: s, startingAt: 0).location == NSNotFound
        }
        let known = spellsClean(word) || spellsClean(word.lowercased())
        if cache.count > 2_000 { cache.removeAll() }
        cache[word] = known
        return known
    }
}
