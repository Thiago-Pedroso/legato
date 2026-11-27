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
        #expect(machine.triggerDown(at: 9) == nil)
        #expect(machine.isRecording)
        #expect(machine.triggerUp(at: 9.1) == .finish)
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

    @Test func acousticMatchesFixNonWordsOnly() {
        let words: Set<String> = ["o", "servidor", "da", "caiu", "de", "novo", "pensou"]
        let matches = [
            TextProcessor.AcousticMatch(heard: "contabu", term: "Contabo", margin: 4.8),
            TextProcessor.AcousticMatch(heard: "caiu de", term: "Claude", margin: 3),
        ]
        let text = TextProcessor.applyAcousticMatches(matches, to: "O servidor da contabu caiu de novo.") {
            words.contains($0)
        }
        #expect(text == "O servidor da Contabo caiu de novo.")
    }

    @Test func acousticMatchesNeedAClearMargin() {
        let matches = [TextProcessor.AcousticMatch(heard: "Pense", term: "Pensy", margin: 0.2)]
        #expect(TextProcessor.applyAcousticMatches(matches, to: "No canal da Pense.") { _ in false } == "No canal da Pense.")
    }

    @Test func acousticMatchesKeepPunctuationAndOrder() {
        let matches = [
            TextProcessor.AcousticMatch(heard: "Cloud Code", term: "Claude Code", margin: 6),
            TextProcessor.AcousticMatch(heard: "contáble.", term: "Contabo", margin: 10),
        ]
        let text = TextProcessor.applyAcousticMatches(matches, to: "Fala com o Cloud Code sobre o deploy na contáble.") {
            _ in false
        }
        #expect(text == "Fala com o Claude Code sobre o deploy na Contabo.")
    }

    @Test func acousticMatchesApplyInAnyOrder() {
        let matches = [
            TextProcessor.AcousticMatch(heard: "contabu", term: "Contabo", margin: 5),
            TextProcessor.AcousticMatch(heard: "pensi", term: "Pensy", margin: 5),
        ]
        #expect(TextProcessor.applyAcousticMatches(matches, to: "pensi e contabu") { _ in false } == "Pensy e Contabo")
    }

    @Test func acousticMatchesLeaveDeliberateNamesAlone() {
        let matches = [TextProcessor.AcousticMatch(heard: "GitHub", term: "GitLab", margin: 4)]
        #expect(TextProcessor.applyAcousticMatches(matches, to: "Abre no GitHub.") { _ in false } == "Abre no GitHub.")
    }

    @Test func acousticMatchesLeaveKnownNamesAlone() {
        // As the dictionary answers: names only capitalized, "Code" too, since it is English.
        let words: Set<String> = ["o", "e", "com", "Artur", "Code"]
        let isWord = { words.contains($0) }
        let artur = [TextProcessor.AcousticMatch(heard: "o Artur,", term: "OAuth", margin: 5)]
        let text = "Falei com o Vitor, o Artur, e o Gustavo."
        #expect(TextProcessor.applyAcousticMatches(artur, to: text, isWord: isWord) == text)
        let claude = [TextProcessor.AcousticMatch(heard: "Clobe Code", term: "Claude Code", margin: 5)]
        #expect(TextProcessor.applyAcousticMatches(claude, to: "Abre o Clobe Code.", isWord: isWord) == "Abre o Claude Code.")
    }

    @Test func processTrimsAndAddsSpace() {
        #expect(TextProcessor.process("  oi tudo bem \n", vocabulary: [], replacements: [], trailingSpace: true) == "oi tudo bem ")
        #expect(TextProcessor.process("   ", vocabulary: [], replacements: [], trailingSpace: true) == "")
    }
}

@Suite struct LanguageCheckTests {
    func check(_ text: String, seconds: TimeInterval = 1, confidence: Float = 0.8, vocabulary: [String] = []) -> Bool {
        LanguageCheck.soundsLikeAnotherLanguage(
            text, expected: "pt", duration: seconds, confidence: confidence, vocabulary: vocabulary)
    }

    @Test func flagsShortClipsHeardInAnotherLanguage() {
        #expect(check("says she"))
        #expect(check("Verlobte sie."))
        #expect(check("Fold you see here."))
    }

    @Test func keepsShortPortuguese() {
        #expect(!check("Teste."))
        #expect(!check("Sim.", confidence: 0.5))
        #expect(!check("Uh, dois, três."))
    }

    @Test func neverJudgesASingleWordOrNumber() {
        for text in ["Oi.", "Tchau.", "Ok", "Show.", "Commit.", "Netflix.", "123.", "42"] {
            #expect(!check(text, confidence: 0.5), "\(text)")
        }
    }

    @Test func trustsLongOrConfidentOrKnownText() {
        #expect(!check("says she", seconds: 4))
        #expect(!check("says she", confidence: 0.95))
        #expect(!check("GitHub", vocabulary: ["GitHub"]))
        #expect(!LanguageCheck.soundsLikeAnotherLanguage(
            "says she", expected: "auto", duration: 1, confidence: 0.5, vocabulary: []))
    }
}

@Suite struct CorrectionTests {
    let words: Set<String> = ["o", "servidor", "da", "caiu", "de", "novo", "isso", "aquilo", "fala", "com", "a"]
    func find(_ pasted: String, _ before: String, _ after: String) -> (heard: String, typed: String)? {
        Corrections.find(pasted: pasted, before: before, after: after) { words.contains($0) }
    }

    @Test func learnsATermTypedOverAMishearing() {
        let pasted = "O servidor da contabu caiu de novo. "
        let found = find(pasted, "Oi! " + pasted, "Oi! O servidor da Contabo caiu de novo. ")
        #expect(found?.heard == "contabu")
        #expect(found?.typed == "Contabo")
    }

    @Test func learnsAPartialRetype() {
        // Only the last letters were retyped; the whole word is what counts.
        let found = find("fala com a vertex", "fala com a vertex", "fala com a Vertyx")
        #expect(found?.heard == "vertex")
        #expect(found?.typed == "Vertyx")
    }

    @Test func ignoresOrdinaryRewordingAndEditsOutsideTheDictation() {
        #expect(find("isso caiu", "isso caiu", "aquilo caiu") == nil)
        #expect(find("o servidor caiu", "Contabu: o servidor caiu", "Contabo: o servidor caiu") == nil)
        #expect(find("o servidor caiu", "o servidor caiu", "o servidor caiu de novo") == nil)
        #expect(find("o servidor caiu", "o servidor caiu", "") == nil)
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

    @Test func cleanupCanBeLimitedToSomeApps() {
        var settings = Settings()
        settings.cleanupEnabled = true
        settings.cleanupModel = "llama"
        #expect(settings.cleansUp(in: "com.apple.Notes"))
        settings.cleanupEverywhere = false
        settings.cleanupApps = ["com.mitchellh.ghostty"]
        #expect(settings.cleansUp(in: "com.mitchellh.ghostty"))
        #expect(!settings.cleansUp(in: "com.apple.Notes"))
        #expect(!settings.cleansUp(in: nil))
        settings.cleanupModel = ""
        #expect(!settings.cleansUp(in: "com.mitchellh.ghostty"))
        // The on-device model needs no model name.
        settings.cleanupEngine = .onDevice
        #expect(settings.cleansUp(in: "com.mitchellh.ghostty"))
    }

    @Test func settingsSurviveMissingKeys() throws {
        let old = #"{"trigger":"rightOption","vocabulary":["Pensy"]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(settings.trigger == .rightOption)
        #expect(settings.vocabulary == ["Pensy"])
        #expect(settings.unloadAfterMinutes == 15)
        #expect(settings.avoidBluetoothMicrophone)
        #expect(settings.checkForUpdates)
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

@Suite struct SpeechEdgeTests {
    @Test func speechStandsWellAboveTheRoom() {
        let room: [Float] = Array(repeating: -58, count: 40) + Array(repeating: -20, count: 60)
        let threshold = SpeechEdge.threshold(levels: room)
        #expect(threshold == -46)
        #expect(-20 > threshold)
        #expect(-57 < threshold)
    }

    @Test func aQuietRoomStillNeedsMinusFiftyToCountAsSpeech() {
        #expect(SpeechEdge.threshold(levels: Array(repeating: -80, count: 50)) == -50)
    }

    @Test func zerosFromAMicrophoneWakingUpAreNotTheRoom() {
        let levels: [Float] = Array(repeating: -100, count: 30) + [-62, -60, -58, -30, -28, -26, -27, -29, -31, -30]
        #expect(SpeechEdge.threshold(levels: levels) == -48)
        #expect(SpeechEdge.threshold(levels: []) == 0)
    }

    @Test func aShortDictationIsJudgedByHowTheSpeakerSounds() {
        // Levels from a real three-second dictation in a noisy room: nearly all of it is speech.
        let levels: [Float] = [-41, -37, -33, -32, -30, -29, -28, -31, -32, -28, -40, -28, -29, -29, -30, -31, -30]
        let threshold = SpeechEdge.threshold(levels: levels)
        #expect(threshold == -40)
        #expect(-30 > threshold)
    }

    @Test func aPauseBetweenWordsIsNotTheEnd() {
        // "…no parque": the key came up in the gap before the "p".
        #expect(SpeechEdge.speaking([-28, -27, -45], above: -40))
        #expect(!SpeechEdge.speaking([-28, -45, -46], above: -40))
        #expect(!SpeechEdge.speaking([], above: -40))
    }
}

@Suite struct DiagnosticsTests {
    @Test func keepsTheNewestLinesOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0..<(DiagnosticsLog.limit + 5) {
            var timing = DictationTiming()
            timing.audio = Double(index)
            DiagnosticsLog.append(timing, to: url)
        }
        let loaded = DiagnosticsLog.load(url)
        #expect(loaded.count == DiagnosticsLog.limit)
        #expect(loaded.first?.audio == 5)
        #expect(loaded.last?.audio == Double(DiagnosticsLog.limit + 4))
    }

    @Test func reportMarksAHeadsetInItsCallProfile() {
        var timing = DictationTiming()
        timing.microphone = "AirPods Pro"
        timing.microphoneRate = 24_000
        timing.bluetoothOutputRate = 24_000
        timing.soundDelay = 0.8
        timing.outcome = "pasted"
        let report = DiagnosticsLog.report([timing], version: "0.4.0")
        #expect(report.contains("AirPods Pro"))
        #expect(report.contains("HFP"))
        #expect(report.contains("800"))
    }
}

@Suite struct ReleaseTests {
    @Test func comparesDottedVersions() {
        #expect(Release.isNewer("v0.4.0", than: "0.3.0"))
        #expect(Release.isNewer("v0.3.1", than: "0.3"))
        #expect(Release.isNewer("v1.0.0", than: "0.10.2"))
        #expect(!Release.isNewer("v0.3.0", than: "0.3.0"))
        #expect(!Release.isNewer("v0.2.9", than: "0.3.0"))
        #expect(!Release.isNewer("v0.4.0-beta", than: "0.3.0"))
    }
}
