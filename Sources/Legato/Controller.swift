import AVFoundation
import AppKit
import Combine
import LegatoCore

/// Where the local model stands, for the menu and the settings window.
enum ModelState: Equatable {
    case missing
    case downloading(Double)
    case loading
    case ready
    /// Downloaded but not in memory.
    case resting
    case failed(String)
}

/// Runs a dictation from key press to pasted text, and owns the pieces that takes.
@MainActor
final class Controller: ObservableObject {
    @Published var settings: Settings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var modelState: ModelState = .missing
    @Published private(set) var hotkeyActive = false

    let pill = PillPanel()
    private let history: HistoryStore
    private let recorder = Recorder()
    private let engine = ParakeetEngine()
    private let hotkey = HotkeyMonitor()
    private var machine = HotkeyStateMachine()
    private var pendingTap: DispatchWorkItem?
    private var unloadTimer: Timer?
    private var working = 0
    private var workingSince = Date()
    private var workingTicker: Timer?
    private var hideTimer: DispatchWorkItem?
    private var lastFailed: UUID?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legato", isDirectory: true)
        history = HistoryStore(directory: support)
        if let data = UserDefaults.standard.data(forKey: "settings"),
            let saved = try? JSONDecoder().decode(Settings.self, from: data)
        {
            settings = saved
        } else {
            settings = Settings()
        }
        entries = history.entries
        modelState = settings.localModel.isDownloaded ? .resting : .missing

        recorder.onLevel = { [weak self] level in self?.pill.model.push(level: level) }
        pill.model.onTap = { [weak self] in self?.pillTapped() }
        hotkey.trigger = settings.trigger
        hotkey.onTrigger = { [weak self] down in self?.trigger(down) }
        hotkey.onOtherKey = { [weak self] in
            guard let self else { return }
            self.perform(self.machine.otherKeyDown(at: Self.now))
        }
        hotkey.onEscape = { [weak self] in
            guard let self, let action = self.machine.escape() else { return false }
            self.perform(action)
            return true
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.warmUp() }
        }
    }

    var recordingsFolder: URL { history.directory }
    var engineName: String { settings.engine == .local ? settings.localModel.title : settings.apiModel }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Start-up

    func launch() {
        startHotkey()
        // The app is useful the moment it opens only if the model is already in memory.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.warmUp() }
    }

    /// The key tap needs Accessibility; keep trying until the user grants it.
    func startHotkey() {
        hotkeyActive = hotkey.start()
        guard !hotkeyActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startHotkey() }
    }

    private func settingsChanged(from old: Settings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
        hotkey.trigger = settings.trigger
        if old.localModel != settings.localModel || old.engine != settings.engine {
            modelState = settings.localModel.isDownloaded ? .resting : .missing
            if settings.engine == .local { warmUp() } else { Task { await engine.unload() } }
        }
        if old.historyLimit != settings.historyLimit { prune() }
    }

    // MARK: Model lifecycle

    /// Loads the local model in the background if it is on disk. Never downloads on its own.
    func warmUp() {
        guard settings.engine == .local, settings.localModel.isDownloaded else { return }
        loadModel()
    }

    /// Downloads if needed and loads. The settings window calls this from its Download button.
    func loadModel() {
        guard settings.engine == .local else { return }
        switch modelState {
        case .downloading, .loading: return
        default: break
        }
        let model = settings.localModel
        modelState = model.isDownloaded ? .loading : .downloading(0)
        Task {
            do {
                try await engine.load(model) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.modelState else { return }
                        self.modelState = fraction >= 1 ? .loading : .downloading(fraction)
                    }
                }
                guard settings.localModel == model else { return }
                modelState = .ready
                scheduleUnload()
            } catch {
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        guard settings.unloadAfterMinutes > 0 else { return }
        unloadTimer = Timer.scheduledTimer(withTimeInterval: Double(settings.unloadAfterMinutes) * 60, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.working == 0, !self.recorder.isRecording else { return }
                await self.engine.unload()
                if self.modelState == .ready { self.modelState = .resting }
            }
        }
    }

    // MARK: Key handling

    private func trigger(_ down: Bool) {
        let action = down ? machine.triggerDown(at: Self.now) : machine.triggerUp(at: Self.now)
        perform(action)
        pendingTap?.cancel()
        if let deadline = machine.pendingDeadline {
            // A lone tap: wait for the second one, then give up.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.perform(self.machine.tick(at: Self.now))
            }
            pendingTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - Self.now) + 0.01, execute: work)
        }
    }

    private func perform(_ action: HotkeyStateMachine.Action?) {
        switch action {
        case .start: startRecording()
        case .lock: pill.show(.recording(handsFree: true))
        case .finish: finishRecording()
        case .cancel: cancelRecording()
        case nil: break
        }
    }

    private func pillTapped() {
        switch pill.model.mode {
        case .recording(handsFree: true):
            machine.reset()
            finishRecording()
        case .failed:
            if let id = lastFailed { retry(id, paste: true) }
        default: break
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard Permissions.microphone == .authorized else {
            machine.reset()
            if Permissions.microphone == .notDetermined {
                Permissions.requestMicrophone { _ in }
            } else {
                flash(.failed(L.t("Microphone access is off", "Sem acesso ao microfone")), seconds: 4)
            }
            return
        }
        do {
            pill.model.resetLevels()
            try recorder.start()
        } catch {
            machine.reset()
            flash(.failed(error.localizedDescription), seconds: 4)
            return
        }
        hideTimer?.cancel()
        if settings.sounds { Self.play("Tink") }
        pill.show(.recording(handsFree: false))
        // Start loading while the user is still talking, so the wait overlaps the speech.
        if modelState == .resting { loadModel() }
    }

    private func cancelRecording() {
        guard recorder.isRecording else { return }
        _ = recorder.stop()
        refreshPill()
    }

    private func finishRecording() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        if settings.sounds { Self.play("Pop") }
        guard samples.count > WAV.sampleRate / 4 else {
            refreshPill()
            return
        }
        let entry: HistoryEntry
        do {
            // Audio goes to disk first. Whatever happens next, the dictation is not lost.
            entry = try history.begin(samples: samples, engine: engineName, error: L.t("Interrupted", "Interrompido"))
            entries = history.entries
        } catch {
            flash(.failed(error.localizedDescription), seconds: 4)
            return
        }
        transcribe(samples, entry: entry.id, paste: true)
    }

    // MARK: Transcription

    func retry(_ id: UUID, paste: Bool) {
        guard let data = try? Data(contentsOf: history.audioURL(for: id)), let samples = WAV.decode(data) else { return }
        transcribe(samples, entry: id, paste: paste)
    }

    private func transcribe(_ samples: [Float], entry id: UUID, paste: Bool) {
        beginWork()
        let settings = self.settings
        Task {
            do {
                var text: String
                switch settings.engine {
                case .local:
                    if modelState == .resting || modelState == .missing { loadModel() }
                    text = try await engine.transcribe(samples, model: settings.localModel, language: settings.language)
                    if modelState != .ready { modelState = .ready }
                    scheduleUnload()
                case .api:
                    text = try await APIEngine.transcribe(
                        samples, baseURL: settings.apiBaseURL, model: settings.apiModel, key: Keychain.get("api"),
                        language: settings.language, vocabulary: settings.vocabulary)
                }
                if settings.cleanupEnabled, !settings.cleanupModel.isEmpty, !text.isEmpty {
                    // Cleanup is a nicety: if it fails or stalls, the plain transcript goes through.
                    text = (try? await APIEngine.cleanUp(
                        text, baseURL: settings.cleanupBaseURL, model: settings.cleanupModel,
                        key: Keychain.get("cleanup"), prompt: settings.cleanupPrompt)) ?? text
                }
                let final = TextProcessor.process(
                    text, vocabulary: settings.vocabulary, replacements: settings.replacements,
                    trailingSpace: settings.trailingSpace)
                endWork()
                if final.isEmpty {
                    history.remove(id)
                    entries = history.entries
                    flash(.notice(L.t("Didn't catch that", "Não entendi")), seconds: 1.6)
                    return
                }
                history.update(id) { $0.text = final; $0.status = .done; $0.error = nil; $0.engine = self.engineName }
                prune()
                if paste, Inserter.insert(final) {
                    refreshPill()
                } else {
                    Inserter.copy(final)
                    flash(.notice(L.t("Copied", "Copiado")), seconds: 1.6)
                }
            } catch {
                endWork()
                history.update(id) { $0.status = .failed; $0.error = error.localizedDescription }
                entries = history.entries
                lastFailed = id
                flash(.failed(L.t("Failed. Click to retry", "Falhou. Clique para tentar de novo")), seconds: 10)
            }
        }
    }

    private func prune() {
        history.prune(keeping: settings.historyLimit)
        entries = history.entries
    }

    // MARK: History

    func delete(_ id: UUID) {
        history.remove(id)
        entries = history.entries
    }

    func clearHistory() {
        history.removeAll()
        entries = []
    }

    func audioURL(_ id: UUID) -> URL? { history.hasAudio(id) ? history.audioURL(for: id) : nil }

    // MARK: Pill

    private func beginWork() {
        working += 1
        guard working == 1 else { return }
        workingSince = Date()
        refreshPill()
        workingTicker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPill() }
        }
    }

    private func endWork() {
        working = max(0, working - 1)
        if working == 0 {
            workingTicker?.invalidate()
            workingTicker = nil
        }
    }

    /// Shows what is true right now: recording wins over working, working over nothing.
    private func refreshPill() {
        if recorder.isRecording { return }
        guard working > 0 else {
            pill.show(.hidden)
            return
        }
        hideTimer?.cancel()
        let elapsed = Int(Date().timeIntervalSince(workingSince))
        var detail: String?
        switch modelState {
        case .loading: detail = L.t("Loading model", "Carregando modelo")
        case .downloading(let fraction): detail = L.t("Downloading model", "Baixando modelo") + " \(Int(fraction * 100))%"
        default: if elapsed >= 3 { detail = "\(elapsed)s" }
        }
        pill.show(.working(detail))
    }

    private func flash(_ mode: PillModel.Mode, seconds: Double) {
        hideTimer?.cancel()
        pill.show(mode)
        let work = DispatchWorkItem { [weak self] in self?.refreshPill() }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }
}
