import AppKit
import FluidAudio
import Foundation
import LegatoCore

/// `Legato vocab ...`: the pieces an assistant (or you) chains together to turn the words
/// in your project folders into vocabulary suggestions. Each step prints JSON.
enum Vocab {
    static func run(_ arguments: [String]) -> Int32 {
        var rest = arguments
        guard !rest.isEmpty else { return CLI.usage() }
        switch rest.removeFirst() {
        case "candidates": return candidates(rest)
        case "probe": return probe(rest)
        case "suggest": return suggest(rest)
        default: return CLI.usage()
        }
    }

    private static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
    }

    // MARK: candidates

    private static func candidates(_ paths: [String]) -> Int32 {
        guard !paths.isEmpty else { return CLI.usage() }
        let folders = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        // Commit subjects are short prose full of the project's own words.
        let logs = folders.compactMap { shell("/usr/bin/git", ["-C", $0.path, "log", "--pretty=%s", "-n", "400"]) }
        let known = Set((AppPaths.loadSettings()?.vocabulary ?? []).map(TextProcessor.normalize))
        let found = VocabularyMiner.scan(folders: folders, extraText: logs).filter { candidate in
            !known.contains(TextProcessor.normalize(candidate.term)) && !isEverydayWord(candidate.term)
        }
        emit(found)
        return 0
    }

    /// A single capitalized word that the dictionary knows is a sentence opener or a heading, not jargon.
    private static func isEverydayWord(_ term: String) -> Bool {
        guard !term.contains(" ") else { return false }
        let letters = term.filter(\.isLetter)
        if letters.allSatisfy(\.isUppercase) { return false }
        if zip(term, term.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) { return false }
        return isInDictionary(term.lowercased())
    }

    static func isInDictionary(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        for language in ["pt_BR", "en"] {
            let range = checker.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if range.location == NSNotFound { return true }
        }
        return false
    }

    // MARK: probe

    struct ProbeResult: Codable {
        var term: String
        /// True when every synthetic voice got the term right. Those terms need no help.
        var ok: Bool
        var heard: [HeardForm]
    }

    private static let carriers: [(voice: String, prefix: String, suffix: String)] = [
        ("Luciana", "Agora eu vou falar sobre", "com você"),
        ("Samantha", "Now I want to talk about", "with you"),
    ]

    private static func probe(_ arguments: [String]) -> Int32 {
        var terms = arguments
        if terms.isEmpty {
            terms = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        }
        guard !terms.isEmpty else { return CLI.usage() }
        let installed = shell("/usr/bin/say", ["-v", "?"]) ?? ""
        let voices = carriers.filter { installed.contains($0.voice + " ") }
        guard !voices.isEmpty else {
            CLI.note("error: no Luciana or Samantha voice installed (System Settings, Accessibility, Spoken Content)")
            return 1
        }
        let model = AppPaths.loadSettings()?.localModel ?? .parakeetUltra
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("legato-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var results: [ProbeResult] = []
        let status = CLI.wait {
            let engine = ParakeetEngine()
            try await engine.load(model)
            for term in terms {
                var heard: [HeardForm] = []
                var ok = true
                var tested = 0
                for carrier in voices {
                    let file = folder.appendingPathComponent("clip.aiff")
                    // Start clean so a failed synthesis can never reuse the previous term's audio.
                    try? FileManager.default.removeItem(at: file)
                    _ = shell("/usr/bin/say", ["-v", carrier.voice, "-o", file.path, "\(carrier.prefix) \(term) \(carrier.suffix)."])
                    guard let samples = try? AudioConverter().resampleAudioFile(path: file.path) else { continue }
                    tested += 1
                    let text = try await engine.transcribe(samples, model: model, language: "pt")
                    let middle = Probe.middle(of: text, prefix: carrier.prefix, suffix: carrier.suffix)
                    if TextProcessor.normalize(middle) == TextProcessor.normalize(term) { continue }
                    ok = false
                    // A long middle means the carrier itself was misheard; that says nothing about the term.
                    let limit = term.split(separator: " ").count + 2
                    guard !middle.isEmpty, middle.split(separator: " ").count <= limit,
                        !heard.contains(where: { TextProcessor.normalize($0.text) == TextProcessor.normalize(middle) })
                    else { continue }
                    let common = middle.split(separator: " ").allSatisfy { isInDictionary($0.lowercased()) }
                    heard.append(HeardForm(text: middle.lowercased(), common: common))
                }
                guard tested > 0 else {
                    CLI.note("skipped \(term)  (could not synthesize it)")
                    continue
                }
                results.append(ProbeResult(term: term, ok: ok, heard: heard))
                CLI.note("\(ok ? "ok    " : "missed") \(term)\(heard.isEmpty ? "" : "  <-  " + heard.map(\.text).joined(separator: " | "))")
            }
        }
        emit(results)
        return status
    }

    // MARK: suggest

    private struct Incoming: Decodable {
        var term: String
        var heard: [HeardForm]?
        var note: String?
        var ok: Bool?
    }

    private static func suggest(_ arguments: [String]) -> Int32 {
        var source = "terminal"
        if let option = arguments.firstIndex(of: "--source"), arguments.count > option + 1 { source = arguments[option + 1] }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let incoming = try? JSONDecoder().decode([Incoming].self, from: input) else {
            CLI.note("error: expected a JSON array like [{\"term\": \"Pensy\", \"heard\": [...], \"note\": \"...\"}] on stdin")
            return 1
        }
        // Terms the model already gets right would only add risk; leave them out.
        let new = incoming.filter { $0.ok != true }.map {
            Suggestion(term: $0.term.trimmingCharacters(in: .whitespaces), heard: $0.heard ?? [], source: source, note: $0.note)
        }
        let existing = SuggestionStore.load(AppPaths.suggestions)
        let merged = SuggestionStore.merge(existing, with: new, vocabulary: AppPaths.loadSettings()?.vocabulary ?? [])
        do {
            try SuggestionStore.save(merged, to: AppPaths.suggestions)
        } catch {
            CLI.note("error: \(error.localizedDescription)")
            return 1
        }
        CLI.note("\(merged.count - existing.count) new suggestions waiting in Legato, Settings, Vocabulary.")
        return 0
    }

    private static func shell(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
