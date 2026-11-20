import Foundation

public struct Candidate: Codable, Equatable {
    public var term: String
    public var count: Int
    /// One line where the term appears, so a reviewer can tell what it is.
    public var example: String
}

/// Finds words in prose that look like names and jargon: the kind of thing a speech model
/// has never seen spelled. It only reads; deciding what is worth keeping comes later.
public enum VocabularyMiner {
    static let proseExtensions: Set<String> = ["md", "mdx", "txt", "rst"]
    static let skippedFolders: Set<String> = [
        "node_modules", "build", "dist", "target", "vendor", "Pods", "venv", "__pycache__",
    ]

    /// Reads the prose files under each folder (README, notes, docs) and returns the most
    /// frequent candidates. Code is left out on purpose: identifiers are not spoken.
    public static func scan(folders: [URL], extraText: [String] = [], limit: Int = 250) -> [Candidate] {
        var tally = Tally()
        for folder in folders {
            tally.add(folder.lastPathComponent)
            guard
                let walker = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            var files = 0
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard proseExtensions.contains(url.pathExtension.lowercased()), (values?.fileSize ?? 0) < 400_000,
                    let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                tally.add(text)
                files += 1
                if files >= 600 { break }
            }
        }
        for text in extraText { tally.add(text) }
        return tally.ranked(limit: limit)
    }

    public static func candidates(in text: String, minimumCount: Int = 1) -> [Candidate] {
        var tally = Tally()
        tally.add(text)
        return tally.ranked(limit: .max, minimumCount: minimumCount)
    }

    struct Tally {
        private var counts: [String: (count: Int, example: String)] = [:]

        mutating func add(_ text: String) {
            for line in stripCode(text).split(whereSeparator: \.isNewline) {
                let line = String(line)
                for term in terms(in: line) {
                    counts[term, default: (0, line.trimmingCharacters(in: .whitespaces))].count += 1
                }
            }
        }

        func ranked(limit: Int, minimumCount: Int = 2) -> [Candidate] {
            counts.filter { $0.value.count >= minimumCount }
                .map { Candidate(term: $0.key, count: $0.value.count, example: String($0.value.example.prefix(140))) }
                .sorted { ($0.count, $1.term) > ($1.count, $0.term) }
                .prefix(limit).map { $0 }
        }
    }

    /// Fenced blocks, inline code and links hold identifiers and paths, not vocabulary.
    static func stripCode(_ text: String) -> String {
        var result = text
        for pattern in ["(?s)```.*?```", "`[^`\\n]*`", "https?://\\S+", "\\]\\([^)]*\\)", "\\S+/\\S+", "\\S+\\.[a-z]{1,5}\\b"] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }

    static func terms(in line: String) -> [String] {
        var found: [String] = []
        var run: [String] = []
        func flushRun() {
            if run.count >= 2 { found.append(run.joined(separator: " ")) }
            run = []
        }
        let edges = CharacterSet.letters.union(.decimalDigits).inverted
        // A word opens a sentence when it starts the line or follows closing punctuation.
        var atStart = true
        for piece in line.split(separator: " ", omittingEmptySubsequences: true) {
            let word = piece.trimmingCharacters(in: edges)
            let endsClause = piece.last.map { ",.;:!?)|".contains($0) } ?? false
            let endsSentence = piece.last.map { ".!?:|".contains($0) } ?? false
            guard word.count >= 2, word.first!.isLetter,
                word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" })
            else {
                flushRun()
                // List bullets, heading marks and table bars start a sentence; a stray word does not.
                atStart = word.isEmpty ? true : endsSentence
                continue
            }
            let capitalized = word.first!.isUppercase
            let letters = word.filter(\.isLetter)
            let acronym = letters.count >= 2 && letters.count <= 6 && letters.allSatisfy(\.isUppercase)
            let humps = zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
                || (letters.count > 6 && word.contains(where: \.isLowercase)
                    && zip(word, word.dropFirst()).contains { $0.isUppercase && $1.isUppercase })
            if acronym || humps {
                found.append(word)
            } else if capitalized, word.count >= 3, !atStart {
                found.append(word)
            }
            // Runs of capitalized words are product and people names: "Claude Code".
            if capitalized, !(atStart && run.isEmpty) { run.append(word) } else { flushRun() }
            // A comma or full stop ends the name: "Groq, OpenAI" is two names, not one.
            if endsClause { flushRun() }
            atStart = endsSentence
        }
        flushRun()
        return found
    }
}

/// How a spoken term came back from the speech model.
public struct HeardForm: Codable, Equatable {
    public var text: String
    /// Made only of ordinary dictionary words. Replacing it everywhere would be wrong.
    public var common: Bool

    public init(text: String, common: Bool) {
        self.text = text
        self.common = common
    }
}

public struct Suggestion: Codable, Equatable, Identifiable {
    public var term: String
    public var heard: [HeardForm]
    public var source: String
    public var note: String?
    public var id: String { TextProcessor.normalize(term) }

    public init(term: String, heard: [HeardForm] = [], source: String, note: String? = nil) {
        self.term = term
        self.heard = heard
        self.source = source
        self.note = note
    }

    /// Literal replacements worth adding along with the term: the misheard forms that the
    /// near-miss correction would not fix on its own and that are not everyday words.
    public var replacements: [Replacement] {
        heard.filter { form in
            // Very short forms ("opi", "cia") collide with real words too easily to replace blindly.
            !form.common && TextProcessor.normalize(form.text).count >= 5 && TextProcessor.normalize(form.text) != id
                && TextProcessor.correctVocabulary(in: form.text, terms: [term]) != term
        }.map { Replacement(from: $0.text, to: term) }
    }
}

public enum SuggestionStore {
    public static func load(_ url: URL) -> [Suggestion] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Suggestion].self, from: data)) ?? []
    }

    public static func save(_ suggestions: [Suggestion], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(suggestions).write(to: url, options: .atomic)
    }

    /// Adds new suggestions, skipping terms already suggested or already in the vocabulary.
    public static func merge(_ existing: [Suggestion], with new: [Suggestion], vocabulary: [String]) -> [Suggestion] {
        var seen = Set(existing.map(\.id)).union(vocabulary.map(TextProcessor.normalize))
        var result = existing
        for suggestion in new where !suggestion.id.isEmpty && seen.insert(suggestion.id).inserted {
            result.append(suggestion)
        }
        return result
    }
}

/// Recovers what the model heard in place of a term spoken inside a known sentence.
public enum Probe {
    /// Drops the carrier's opening and closing words from the transcript; what is left is the term as heard.
    public static func middle(of heard: String, prefix: String, suffix: String) -> String {
        func split(_ value: String) -> [String] {
            value.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }.filter { !$0.isEmpty }
        }
        var words = split(heard)
        for expected in split(prefix) {
            guard let first = words.first, TextProcessor.normalize(first) == TextProcessor.normalize(expected) else { break }
            words.removeFirst()
        }
        for expected in split(suffix).reversed() {
            guard let last = words.last, TextProcessor.normalize(last) == TextProcessor.normalize(expected) else { break }
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}

public enum AppPaths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legato", isDirectory: true)
    }
    public static var settings: URL { support.appendingPathComponent("settings.json") }
    public static var suggestions: URL { support.appendingPathComponent("suggestions.json") }

    public static func loadSettings() -> Settings? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }
}
