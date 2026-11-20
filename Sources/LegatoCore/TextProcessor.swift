import Foundation

public struct Replacement: Codable, Equatable, Identifiable {
    public var id: UUID
    public var from: String
    public var to: String

    public init(id: UUID = UUID(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// Cleans up a raw transcript: fixes vocabulary terms the model nearly got right,
/// then applies the user's literal replacements.
public enum TextProcessor {
    public static func process(
        _ raw: String, vocabulary: [String], replacements: [Replacement], trailingSpace: Bool
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = correctVocabulary(in: text, terms: vocabulary)
        text = applyReplacements(in: text, replacements)
        return trailingSpace ? text + " " : text
    }

    /// Whole-word, case-insensitive literal replacement.
    public static func applyReplacements(in text: String, _ replacements: [Replacement]) -> String {
        var result = text
        for item in replacements {
            let from = item.from.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: item.to))
        }
        return result
    }

    /// Replaces words that are within a small edit distance of a vocabulary term with the term,
    /// spelled and cased the way the user wrote it. "cloud code" does not become "Claude Code";
    /// "claud code" does.
    public static func correctVocabulary(in text: String, terms: [String], tolerance: Double = 0.2) -> String {
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return text }
        // Longer terms first so "Claude Code" wins over "Claude".
        let targets = cleaned.sorted { $0.count > $1.count }.map { term in
            (term: term, key: normalize(term), words: term.split(separator: " ").count)
        }
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map { Word(String($0)) }
        var index = 0
        while index < words.count {
            var matched = false
            for target in targets {
                // Try the term's own word count first, then one word fewer or more, and keep the closest.
                var best: (size: Int, score: Double)?
                for size in [target.words, target.words - 1, target.words + 1]
                where size >= 1 && index + size <= words.count {
                    let window = words[index..<(index + size)]
                    // Punctuation inside the window means it spans two phrases.
                    if window.dropLast().contains(where: { !$0.trailing.isEmpty })
                        || window.dropFirst().contains(where: { !$0.leading.isEmpty }) { continue }
                    let key = normalize(window.map(\.core).joined())
                    guard !key.isEmpty, let score = distance(key, target.key), score <= tolerance else { continue }
                    // If the match is as good without the first word, that word is a neighbour:
                    // leave it for the next position.
                    if size > 1, let inner = distance(normalize(window.dropFirst().map(\.core).joined()), target.key),
                        inner <= score { continue }
                    if best == nil || score < best!.score { best = (size, score) }
                }
                if let best {
                    let window = words[index..<(index + best.size)]
                    let merged = Word(leading: window.first!.leading, core: target.term, trailing: window.last!.trailing)
                    words.replaceSubrange(index..<(index + best.size), with: [merged])
                    matched = true
                }
                if matched { break }
            }
            index += 1
        }
        return words.map(\.text).joined(separator: " ")
    }

    private struct Word {
        var leading: String
        var core: String
        var trailing: String

        init(leading: String, core: String, trailing: String) {
            self.leading = leading
            self.core = core
            self.trailing = trailing
        }

        init(_ raw: String) {
            let isEdge: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
            let lead = raw.prefix(while: isEdge)
            let rest = raw.dropFirst(lead.count)
            let trail = String(rest.reversed().prefix(while: isEdge).reversed())
            leading = String(lead)
            core = String(rest.dropLast(trail.count))
            trailing = trail
        }

        var text: String { leading + core + trailing }
    }

    public static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Edit distance as a share of the longer string, or nil when the two are not comparable.
    private static func distance(_ a: String, _ b: String) -> Double? {
        if a == b { return 0 }
        let longest = max(a.count, b.count)
        // Short terms only match exactly: one edit on a four-letter word is a different word.
        guard longest >= 5, abs(a.count - b.count) <= 2 else { return nil }
        return Double(levenshtein(a, b)) / Double(longest)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
