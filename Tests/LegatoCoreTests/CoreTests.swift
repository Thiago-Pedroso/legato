import Foundation
import Testing

@testable import LegatoCore

@Suite struct HotkeyTests {
    @Test func holdRecordsUntilRelease() {
        var machine = HotkeyStateMachine()
        #expect(machine.triggerDown(at: 0) == .start)
        #expect(machine.triggerUp(at: 2) == .finish)
        #expect(machine.state == .idle)
    }

    @Test func doubleTapLocksAndThirdTapFinishes() {
        var machine = HotkeyStateMachine()
        #expect(machine.triggerDown(at: 0) == .start)
        #expect(machine.triggerUp(at: 0.1) == nil)
        #expect(machine.triggerDown(at: 0.3) == .lock)
        #expect(machine.triggerUp(at: 0.4) == nil)
        #expect(machine.tick(at: 5) == nil)
        #expect(machine.triggerDown(at: 9) == .finish)
        #expect(machine.triggerUp(at: 9.1) == nil)
        #expect(machine.state == .idle)
    }

    @Test func singleTapIsDiscarded() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(at: 0)
        _ = machine.triggerUp(at: 0.1)
        #expect(machine.tick(at: 0.3) == nil)
        #expect(machine.tick(at: 0.6) == .cancel)
        #expect(machine.state == .idle)
    }

    @Test func triggerUsedAsModifierCancels() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(at: 0)
        #expect(machine.otherKeyDown(at: 0.2) == .cancel)
    }

    @Test func typingLateInAHoldDoesNotCancel() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(at: 0)
        #expect(machine.otherKeyDown(at: 5) == nil)
        #expect(machine.triggerUp(at: 6) == .finish)
    }

    @Test func escapeCancelsHandsFree() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(at: 0)
        _ = machine.triggerUp(at: 0.1)
        _ = machine.triggerDown(at: 0.2)
        #expect(machine.escape() == .cancel)
        #expect(machine.escape() == nil)
    }
}

@Suite struct TextProcessorTests {
    @Test func fixesNearMissesOfVocabulary() {
        let text = TextProcessor.correctVocabulary(in: "abre o claud code e o pensi.", terms: ["Claude Code", "Pensy"])
        #expect(text == "abre o Claude Code e o Pensy.")
    }

    @Test func joinsSplitTerms() {
        #expect(TextProcessor.correctVocabulary(in: "sobe no git hub", terms: ["GitHub"]) == "sobe no GitHub")
    }

    @Test func leavesDifferentWordsAlone() {
        let text = "a cloud está cara, cláudio"
        #expect(TextProcessor.correctVocabulary(in: text, terms: ["Claude"]) == text)
    }

    @Test func doesNotMatchAcrossPunctuation() {
        let text = "falei com o git. Hub é outra coisa"
        #expect(TextProcessor.correctVocabulary(in: text, terms: ["GitHub"]) == text)
    }

    @Test func replacementsAreWholeWord() {
        let rules = [Replacement(from: "pr", to: "pull request")]
        #expect(TextProcessor.applyReplacements(in: "abre um PR para o projeto", rules) == "abre um pull request para o projeto")
    }

    @Test func processTrimsAndAddsSpace() {
        #expect(TextProcessor.process("  oi tudo bem \n", vocabulary: [], replacements: [], trailingSpace: true) == "oi tudo bem ")
        #expect(TextProcessor.process("   ", vocabulary: [], replacements: [], trailingSpace: true) == "")
    }
}

@Suite struct StorageTests {
    @Test func wavRoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let decoded = WAV.decode(WAV.encode(samples))!
        #expect(decoded.count == samples.count)
        for (a, b) in zip(samples, decoded) { #expect(abs(a - b) < 0.001) }
    }

    @Test func historyKeepsAudioUntilPruned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let first = try store.begin(samples: [0, 0.1], engine: "test", error: "pending")
        let second = try store.begin(samples: [0, 0.2], engine: "test", error: "pending")
        store.update(second.id) { $0.status = .done; $0.text = "oi"; $0.error = nil }

        let reopened = HistoryStore(directory: directory)
        #expect(reopened.entries.map(\.id) == [second.id, first.id])
        #expect(reopened.entries[0].text == "oi")
        #expect(reopened.hasAudio(first.id))

        reopened.prune(keeping: 1)
        #expect(reopened.entries.count == 1)
        #expect(!reopened.hasAudio(first.id))
    }

    @Test func settingsSurviveMissingKeys() throws {
        let old = #"{"trigger":"rightOption","vocabulary":["Pensy"]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(settings.trigger == .rightOption)
        #expect(settings.vocabulary == ["Pensy"])
        #expect(settings.unloadAfterMinutes == 15)
    }
}

@Suite struct VocabularyMiningTests {
    @Test func findsNamesAndJargonInProse() {
        let text = """
            # Notas da semana
            Falei com a Pensy sobre o deploy. O Claude Code abriu um PR no GitHub.
            Depois a Pensy respondeu. O Claude Code ajudou de novo.
            Rode `MinhaClasseInterna.run()` e veja https://exemplo.com/CoisaQualquer.
            """
        let terms = VocabularyMiner.candidates(in: text).map(\.term)
        #expect(terms.contains("Pensy"))
        #expect(terms.contains("Claude Code"))
        #expect(terms.contains("GitHub"))
        #expect(terms.contains("PR"))
        #expect(!terms.contains("Falei"))
        #expect(!terms.contains("Depois"))
        #expect(!terms.contains("MinhaClasseInterna"))
        #expect(!terms.contains("CoisaQualquer"))
    }

    @Test func probeRecoversTheMisheardTerm() {
        let heard = "Agora eu vou falar sobre pensi com você."
        #expect(Probe.middle(of: heard, prefix: "Agora eu vou falar sobre", suffix: "com você") == "pensi")
        #expect(Probe.middle(of: "Agora vou falar de cloud code", prefix: "Agora eu vou falar sobre", suffix: "com você") == "vou falar de cloud code")
    }

    @Test func suggestionAddsOnlyReplacementsThatHelp() {
        let suggestion = Suggestion(
            term: "Pensy",
            heard: [
                HeardForm(text: "pensi", common: false),  // close enough: the correction handles it
                HeardForm(text: "lambreta", common: true),  // an everyday word: never replace
                HeardForm(text: "lem bree ai", common: false),
            ], source: "test")
        #expect(suggestion.replacements.map(\.from) == ["lem bree ai"])
    }

    @Test func mergeSkipsKnownTerms() {
        let existing = [Suggestion(term: "Pensy", source: "a")]
        let merged = SuggestionStore.merge(
            existing, with: [Suggestion(term: "pensy", source: "b"), Suggestion(term: "GitHub", source: "b"), Suggestion(term: "Vertyx", source: "b")],
            vocabulary: ["github"])
        #expect(merged.map(\.term) == ["Pensy", "Vertyx"])
    }
}

@Suite struct MiningPunctuationTests {
    @Test func namesInAListStaySeparate() {
        let terms = VocabularyMiner.candidates(in: "Falei que uso Groq, OpenAI e o Claude. Code não entra.").map(\.term)
        #expect(terms.contains("OpenAI"))
        #expect(!terms.contains("Groq OpenAI"))
        #expect(!terms.contains("Claude Code"))
    }
}
