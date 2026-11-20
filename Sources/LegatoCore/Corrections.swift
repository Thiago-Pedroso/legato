import Foundation

/// Spots the user fixing a word Legato typed, which is the surest sign of a term worth learning.
public enum Corrections {
    /// Compares a text field right after a dictation was pasted (`before`) with the same field
    /// later (`after`). Returns the words the model wrote and what the user typed over them, when
    /// that one edit sits inside the dictation, is a few words long, is spelled like what it
    /// replaced, and turns it into something that is not ordinary language (`isWord`).
    public static func find(
        pasted: String, before: String, after: String, isWord: (String) -> Bool
    ) -> (heard: String, typed: String)? {
        let dictation = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictation.isEmpty, let pastedRange = before.range(of: dictation, options: .backwards) else { return nil }
        let old = Array(before), new = Array(after)
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var tail = 0
        while tail < old.count - start, tail < new.count - start, old[old.count - 1 - tail] == new[new.count - 1 - tail] {
            tail += 1
        }
        // Widen the edit to whole words. Both sides share the text around it, so they widen alike.
        func inWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while start > 0, inWord(old[start - 1]) { start -= 1 }
        while tail > 0, inWord(old[old.count - tail]) { tail -= 1 }

        let lower = before.distance(from: before.startIndex, to: pastedRange.lowerBound)
        let upper = before.distance(from: before.startIndex, to: pastedRange.upperBound)
        guard start >= lower, old.count - tail <= upper else { return nil }

        let heard = String(old[start..<(old.count - tail)]).trimmingCharacters(in: .whitespaces)
        let typed = String(new[start..<(new.count - tail)]).trimmingCharacters(in: .whitespaces)
        let heardWords = heard.split(separator: " "), typedWords = typed.split(separator: " ")
        guard (1...3).contains(heardWords.count), (1...3).contains(typedWords.count),
            !typed.contains(where: \.isNewline)
        else { return nil }
        let a = TextProcessor.normalize(heard), b = TextProcessor.normalize(typed)
        guard a != b, b.count >= 3 else { return nil }
        // A rewrite, not a respelling: "contabu" to "Contabo" counts, "isso" to "aquilo" does not.
        let distance = Double(TextProcessor.levenshtein(a, b)) / Double(max(a.count, b.count))
        guard distance <= 0.6 else { return nil }
        let words = typed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
        guard !words.isEmpty, !words.allSatisfy(isWord) else { return nil }
        return (heard, typed)
    }
}
