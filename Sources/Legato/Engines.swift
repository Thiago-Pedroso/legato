import CoreML
import FluidAudio
import Foundation
import LegatoCore

enum EngineError: LocalizedError {
    case api(String)
    case badURL

    var errorDescription: String? {
        switch self {
        case .api(let message): return message
        case .badURL: return L.t("The API address is not valid.", "O endereço da API não é válido.")
        }
    }
}

extension LocalModel {
    var version: AsrModelVersion {
        switch self {
        case .parakeetUltra: return .ultra
        case .parakeetV3: return .v3
        }
    }

    var title: String {
        switch self {
        case .parakeetUltra: return "Parakeet Ultra"
        case .parakeetV3: return "Parakeet v3"
        }
    }

    var sizeLabel: String {
        switch self {
        case .parakeetUltra: return "630 MB"
        case .parakeetV3: return "480 MB"
        }
    }

    var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }
}

/// The local speech model. Loading is slow the first time (Core ML compiles it for this Mac)
/// and fast afterwards, so callers load early and keep it around.
///
/// With a vocabulary, a second, small model listens to each dictation again for the listed
/// terms. It is prepared in the background and used once ready; a dictation never waits for it.
actor ParakeetEngine {
    struct Transcript {
        var text: String
        var confidence: Float
        /// Terms the second listen found, to be weighed by `TextProcessor.applyAcousticMatches`.
        var matches: [TextProcessor.AcousticMatch]
    }

    private var manager: AsrManager?
    private var loaded: LocalModel?
    private var loading: (model: LocalModel, task: Task<AsrManager, Error>)?
    private var progress: @Sendable (Double) -> Void = { _ in }
    private var ctcModels: CtcModels?
    private var boosting: (terms: [String], session: VocabularyBoostingSession)?
    private var preparing: (terms: [String], task: Task<Void, Never>)?

    /// Download progress goes here no matter which caller started the load.
    func onProgress(_ handler: @escaping @Sendable (Double) -> Void) { progress = handler }

    /// Downloads if needed, loads, and runs one silent clip so the first real dictation is fast.
    /// Returns the ready model, so a caller never has to guess whether loading has finished.
    @discardableResult
    func load(_ model: LocalModel) async throws -> AsrManager {
        if loaded == model, let manager { return manager }
        if let loading, loading.model == model { return try await loading.task.value }
        let progress = self.progress
        let task = Task { () -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: model.version) { update in
                progress(update.fractionCompleted)
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            _ = try? await manager.transcribe([Float](repeating: 0, count: WAV.sampleRate), decoderState: &state)
            return manager
        }
        loading = (model, task)
        let ready: AsrManager
        do {
            ready = try await task.value
        } catch {
            if loading?.task == task { loading = nil }
            throw error
        }
        if loading?.task == task { loading = nil }
        // Detach the old model before cleaning it, so nothing picks it up half torn down.
        let old = manager
        manager = ready
        loaded = model
        if old !== ready { await old?.cleanup() }
        return ready
    }

    func unload() async {
        let old = manager
        manager = nil
        loaded = nil
        boosting = nil
        ctcModels = nil
        preparing?.task.cancel()
        preparing = nil
        await old?.cleanup()
    }

    /// Gets the vocabulary listener ready for these terms, downloading its model the first time.
    /// Failures are left silent: without it, dictation still works with text-only corrections.
    func prepareVocabulary(_ terms: [String]) {
        if terms.isEmpty {
            boosting = nil
            return
        }
        if boosting?.terms == terms || preparing?.terms == terms { return }
        preparing?.task.cancel()
        let task = Task {
            do {
                let models: CtcModels
                if let ctcModels {
                    models = ctcModels
                } else {
                    models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                    ctcModels = models
                }
                let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
                let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: models)
                guard !Task.isCancelled else { return }
                boosting = (terms, session)
            } catch {}
            if preparing?.terms == terms { preparing = nil }
        }
        preparing = (terms, task)
    }

    /// Waits for `prepareVocabulary` to finish. For the command line, where there is no hurry.
    func vocabularyReady() async {
        await preparing?.task.value
    }

    func transcribe(_ samples: [Float], model: LocalModel, language: String) async throws -> Transcript {
        let manager = try await load(model)
        // The model rejects clips under a second; pad instead of failing on a short word.
        var audio = samples
        if audio.count < WAV.sampleRate { audio += [Float](repeating: 0, count: WAV.sampleRate - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state, language: Language(rawValue: language))
        var matches: [TextProcessor.AcousticMatch] = []
        // The cheap text check first: most dictations hold nothing close to a term.
        if let session = boosting?.session, let timings = result.tokenTimings,
            session.hasCTCRescoringCandidates(text: result.text, tokenTimings: timings),
            let output = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: audio)
        {
            matches = output.replacements.compactMap { item in
                guard item.shouldReplace, let term = item.replacementWord, let score = item.replacementScore
                else { return nil }
                return TextProcessor.AcousticMatch(heard: item.originalWord, term: term, margin: score - item.originalScore)
            }
        }
        return Transcript(text: result.text, confidence: result.confidence, matches: matches)
    }
}

extension ParakeetEngine.Transcript {
    /// The text with the terms the second listen found, kept off ordinary words of the language.
    func corrected(language: String) -> String {
        let dictionary = Spelling.dictionary(for: language)
        return TextProcessor.applyAcousticMatches(matches, to: text) { Spelling.isWord($0, in: [dictionary]) }
    }
}

/// Any service that speaks the OpenAI transcription API: Groq, OpenAI, or a server of your own.
enum APIEngine {
    static func transcribe(
        _ samples: [Float], baseURL: String, model: String, key: String, language: String, vocabulary: [String]
    ) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?
            .appendingPathComponent("audio/transcriptions")
        else { throw EngineError.badURL }
        let boundary = "legato-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        if language != "auto" { field("language", language) }
        if !vocabulary.isEmpty { field("prompt", vocabulary.joined(separator: ", ")) }
        body.append(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
                .data(using: .utf8)!)
        body.append(WAV.encode(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let json = try await send(request, body: body)
        return (json["text"] as? String) ?? ""
    }

    /// Optional pass through a chat model to tidy the transcript.
    static func cleanUp(_ text: String, baseURL: String, model: String, key: String, prompt: String) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?
            .appendingPathComponent("chat/completions")
        else { throw EngineError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let payload: [String: Any] = [
            "model": model, "temperature": 0,
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": text]],
        ]
        let json = try await send(request, body: try JSONSerialization.data(withJSONObject: payload))
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let cleaned = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? text : cleaned
    }

    private static func send(_ request: URLRequest, body: Data) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = ((parsed?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw EngineError.api(detail)
        }
        // An answer that is not the expected JSON is a failure to retry, not silence.
        guard let parsed else { throw EngineError.api(L.t("Unexpected answer from the API", "Resposta inesperada da API")) }
        return parsed
    }
}
