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
