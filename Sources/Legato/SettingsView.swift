import AVFoundation
import AppKit
import LegatoCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: Controller
    @State var tab = 0

    private var sections: [(title: String, icon: String)] {
        [
            (L.t("General", "Geral"), "gearshape"),
            (L.t("Transcription", "Transcrição"), "waveform"),
            (L.t("Vocabulary", "Vocabulário"), "character.book.closed"),
            (L.t("History", "Histórico"), "clock"),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(sections[tab].title).font(.title2.weight(.semibold))
                    .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 2)
                Group {
                    switch tab {
                    case 0: GeneralTab(controller: controller)
                    case 1: TranscriptionTab(controller: controller)
                    case 2: VocabularyTab(controller: controller)
                    default: HistoryTab(controller: controller)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(Theme.cobalt)
        .frame(width: 740, height: 540)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                SlurMark().fill(Theme.cobaltAdaptive).frame(width: 26, height: 26)
                Text("legato").font(.system(size: 22, weight: .medium, design: .serif)).italic()
            }
            .padding(.leading, 8).padding(.bottom, 18)
            .accessibilityElement(children: .ignore).accessibilityLabel("Legato")
            ForEach(sections.indices, id: \.self) { index in
                Button { tab = index } label: {
                    HStack(spacing: 9) {
                        Image(systemName: sections[index].icon).frame(width: 18)
                            .foregroundStyle(tab == index ? Theme.cobaltAdaptive : Color.secondary)
                        Text(sections[index].title)
                        Spacer()
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(tab == index ? 0.09 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == index ? .isSelected : [])
            }
            Spacer()
            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"))
                .font(.caption).foregroundStyle(.tertiary).padding(.leading, 9)
        }
        .padding(.horizontal, 12).padding(.top, 52).padding(.bottom, 16)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var controller: Controller
    @State private var microphone = Permissions.microphone
    @State private var accessibility = Permissions.accessibility
    @State private var fnAction = Permissions.fnKeyAction
    @State private var loginItem = LoginItem.isEnabled
    @State private var inputs = AudioDevices.inputs()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker(L.t("Dictation key", "Tecla de ditado"), selection: $controller.settings.trigger) {
                    ForEach(TriggerKey.allCases) { key in Text(key.title).tag(key) }
                }
                Text(
                    L.t(
                        "Hold to talk and release to finish. Tap twice to keep recording hands-free, then tap once to finish. Esc cancels.",
                        "Segure para falar e solte para terminar. Toque duas vezes para gravar com as mãos livres e uma vez para terminar. Esc cancela.")
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker(L.t("Microphone", "Microfone"), selection: $controller.settings.microphone) {
                    Text(L.t("System default", "Padrão do sistema")).tag("")
                    ForEach(inputs) { device in Text(device.name).tag(device.uid) }
                    if !controller.settings.microphone.isEmpty,
                        !inputs.contains(where: { $0.uid == controller.settings.microphone })
                    {
                        Text(L.t("Not connected", "Desconectado")).tag(controller.settings.microphone)
                    }
                }
                Toggle(
                    L.t("Mute the speakers while recording", "Silenciar o som do Mac enquanto grava"),
                    isOn: $controller.settings.muteWhileRecording)
            }
            Section {
                Toggle(L.t("Play a sound when recording starts and stops", "Tocar um som ao começar e terminar"), isOn: $controller.settings.sounds)
                Toggle(L.t("Add a space after each dictation", "Adicionar um espaço depois de cada ditado"), isOn: $controller.settings.trailingSpace)
                Toggle(L.t("Open Legato at login", "Abrir o Legato ao iniciar a sessão"), isOn: $loginItem)
                    .onChange(of: loginItem) { _, value in LoginItem.set(value) }
            }
            Section(L.t("Permissions", "Permissões")) {
                StepRow(
                    done: microphone == .authorized, title: L.t("Microphone", "Microfone"),
                    detail: L.t("To hear what you dictate.", "Para ouvir o que você dita."),
                    button: L.t("Allow", "Permitir")
                ) {
                    if microphone == .notDetermined {
                        Permissions.requestMicrophone { _ in microphone = Permissions.microphone }
                    } else {
                        Permissions.open(Permissions.microphonePane)
                    }
                }
                StepRow(
                    done: accessibility, title: L.t("Accessibility", "Acessibilidade"),
                    detail: L.t(
                        "To notice the shortcut and type the text for you.",
                        "Para perceber o atalho e digitar o texto por você."),
                    button: L.t("Open Settings", "Abrir Ajustes")
                ) {
                    Permissions.requestAccessibility()
                    Permissions.open(Permissions.accessibilityPane)
                }
                if controller.settings.engine == .local, controller.modelState != .ready, controller.modelState != .resting {
                    StepRow(
                        done: false, title: L.t("Speech model", "Modelo de voz"), detail: modelDetail,
                        button: L.t("Download", "Baixar"), busy: modelBusy
                    ) { controller.loadModel() }
                }
                if controller.settings.trigger == .fn, fnAction != 0 {
                    StepRow(
                        done: false, title: L.t("The fn key", "A tecla fn"),
                        detail: L.t(
                            "macOS also reacts to fn. In Keyboard settings, set \"Press 🌐 key to\" to \"Do Nothing\".",
                            "O macOS também reage ao fn. Em Teclado, mude \"Pressione a tecla 🌐 para\" para \"Não Fazer Nada\"."),
                        button: L.t("Open Keyboard", "Abrir Teclado")
                    ) { Permissions.open(Permissions.keyboardPane) }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            microphone = Permissions.microphone
            accessibility = Permissions.accessibility
            fnAction = Permissions.fnKeyAction
            let current = AudioDevices.inputs()
            if current != inputs { inputs = current }
        }
    }

    private var modelBusy: Double? {
        switch controller.modelState {
        case .downloading(let fraction): return fraction
        case .loading: return -1
        default: return nil
        }
    }

    private var modelDetail: String {
        let model = controller.settings.localModel
        switch controller.modelState {
        case .missing:
            return L.t(
                "\(model.title), \(model.sizeLabel). Runs on this Mac; nothing you say leaves it.",
                "\(model.title), \(model.sizeLabel). Roda neste Mac; nada do que você diz sai dele.")
        case .downloading(let fraction): return L.t("Downloading", "Baixando") + " \(Int(fraction * 100))%"
        case .loading: return L.t("Preparing the model for this Mac. The first time takes a minute or two.", "Preparando o modelo para este Mac. A primeira vez leva um ou dois minutos.")
        case .ready, .resting: return "\(model.title)"
        case .failed(let message): return message
        }
    }
}

private struct StepRow: View {
    var done: Bool
    var title: String
    var detail: String
    var button: String
    /// 0...1 shows a progress bar, a negative value a spinner.
    var busy: Double? = nil
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.cobaltAdaptive : Color.secondary)
                .font(.title3)
                .accessibilityLabel(done ? L.t("Done", "Feito") : L.t("Pending", "Pendente"))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let busy, busy >= 0 { ProgressView(value: busy).tint(Theme.cobalt) }
            }
            Spacer()
            if let busy, busy < 0 {
                ProgressView().controlSize(.small)
            } else if !done, busy == nil {
                Button(button, action: action)
            }
        }
    }
}

// MARK: Transcription

private struct TranscriptionTab: View {
    @ObservedObject var controller: Controller
    @State private var apiKey = Keychain.get("api")
    @State private var cleanupKey = Keychain.get("cleanup")

    var body: some View {
        Form {
            Section {
                Picker(L.t("Transcribe", "Transcrever"), selection: $controller.settings.engine) {
                    Text(L.t("On this Mac", "Neste Mac")).tag(EngineKind.local)
                    Text(L.t("With an API", "Com uma API")).tag(EngineKind.api)
                }
                if controller.settings.engine == .local {
                    Picker(L.t("Model", "Modelo"), selection: $controller.settings.localModel) {
                        ForEach(LocalModel.allCases) { model in
                            Text("\(model.title) (\(model.sizeLabel))").tag(model)
                        }
                    }
                    LabeledContent(L.t("Status", "Situação")) {
                        HStack(spacing: 8) {
                            Text(status)
                            if controller.modelState == .missing {
                                Button(L.t("Download", "Baixar")) { controller.loadModel() }
                            }
                        }
                    }
                    Picker(L.t("Keep in memory", "Manter na memória"), selection: $controller.settings.unloadAfterMinutes) {
                        Text(L.t("5 minutes", "5 minutos")).tag(5)
                        Text(L.t("15 minutes", "15 minutos")).tag(15)
                        Text(L.t("1 hour", "1 hora")).tag(60)
                        Text(L.t("Always", "Sempre")).tag(0)
                    }
                    Text(
                        L.t(
                            "After this long without dictating, the model leaves memory. It comes back while you speak, so you rarely wait.",
                            "Depois desse tempo sem ditar, o modelo sai da memória. Ele volta enquanto você fala, então a espera é rara.")
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    TextField(L.t("Address", "Endereço"), text: $controller.settings.apiBaseURL)
                    TextField(L.t("Model", "Modelo"), text: $controller.settings.apiModel)
                    SecureField(L.t("Key", "Chave"), text: $apiKey)
                        .onChange(of: apiKey) { _, value in Keychain.set("api", value) }
                    Text(
                        L.t(
                            "Any service with the OpenAI transcription API works: Groq, OpenAI, or a server of your own. Your audio is sent to it.",
                            "Serve qualquer serviço com a API de transcrição da OpenAI: Groq, OpenAI ou um servidor seu. Seu áudio é enviado para ele.")
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                Picker(L.t("Language", "Idioma"), selection: $controller.settings.language) {
                    Text("Português").tag("pt")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text(L.t("Detect", "Detectar")).tag("auto")
                }
            }
            Section(L.t("Cleanup", "Limpeza")) {
                Toggle(L.t("Tidy the text with an AI model", "Arrumar o texto com um modelo de IA"), isOn: $controller.settings.cleanupEnabled)
                if controller.settings.cleanupEnabled {
                    TextField(L.t("Address", "Endereço"), text: $controller.settings.cleanupBaseURL)
                    TextField(L.t("Model", "Modelo"), text: $controller.settings.cleanupModel, prompt: Text("llama-3.3-70b-versatile"))
                    SecureField(L.t("Key", "Chave"), text: $cleanupKey)
                        .onChange(of: cleanupKey) { _, value in Keychain.set("cleanup", value) }
                    TextField(L.t("Instructions", "Instruções"), text: $controller.settings.cleanupPrompt, axis: .vertical)
                        .lineLimit(3...6)
                    Picker(L.t("Use in", "Usar em"), selection: $controller.settings.cleanupEverywhere) {
                        Text(L.t("Every app", "Todos os aplicativos")).tag(true)
                        Text(L.t("Only these apps", "Só nestes aplicativos")).tag(false)
                    }
                    if !controller.settings.cleanupEverywhere {
                        ForEach(controller.settings.cleanupApps, id: \.self) { id in
                            HStack {
                                AppLabel(bundleID: id)
                                Spacer()
                                Button {
                                    controller.settings.cleanupApps.removeAll { $0 == id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(L.t("Remove", "Remover"))
                            }
                        }
                        Menu(L.t("Add app", "Adicionar aplicativo")) {
                            ForEach(runningApps, id: \.self) { id in
                                Button(AppLabel.name(of: id)) { controller.settings.cleanupApps.append(id) }
                            }
                        }
                        .fixedSize()
                    }
                }
                Text(
                    L.t(
                        "Removes filler words and fixes punctuation. Off by default: it sends the text to the service you choose and adds a short wait.",
                        "Tira vícios de fala e ajusta a pontuação. Vem desligado: envia o texto ao serviço que você escolher e soma uma pequena espera.")
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Apps open now that are not on the list yet, by name.
    private var runningApps: [String] {
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Bundle.main.bundleIdentifier && !controller.settings.cleanupApps.contains($0) }
        return Array(Set(ids)).sorted { AppLabel.name(of: $0) < AppLabel.name(of: $1) }
    }

    private var status: String {
        switch controller.modelState {
        case .missing: return L.t("Not downloaded", "Não baixado")
        case .downloading(let fraction): return L.t("Downloading", "Baixando") + " \(Int(fraction * 100))%"
        case .loading: return L.t("Loading", "Carregando")
        case .ready: return L.t("In memory", "Na memória")
        case .resting: return L.t("Downloaded", "Baixado")
        case .failed(let message): return message
        }
    }
}

/// An app's icon and name from its bundle identifier.
private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 18, height: 18)
            }
            Text(Self.name(of: bundleID))
        }
    }

    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: Vocabulary

private struct VocabularyTab: View {
    @ObservedObject var controller: Controller
    @State private var term = ""
    @State private var from = ""
    @State private var to = ""
    /// Suggestions the user unticked. Everything else is accepted by "Add selected".
    @State private var skipped: Set<String> = []
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !controller.suggestions.isEmpty {
                Section {
                    ForEach(controller.suggestions) { suggestion in
                        Toggle(isOn: Binding(
                            get: { !skipped.contains(suggestion.id) },
                            set: { on in if on { skipped.remove(suggestion.id) } else { skipped.insert(suggestion.id) } })
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.term)
                                Text(detail(suggestion)).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    // The list can be long; the actions stay at the top where they are always in reach.
                    HStack {
                        Text(L.t("Suggestions", "Sugestões") + " (\(controller.suggestions.count))")
                        Spacer()
                        Button(L.t("Dismiss All", "Dispensar todas")) {
                            controller.dismiss(Set(controller.suggestions.map(\.id)))
                            skipped = []
                        }
                        Button(L.t("Add Selected", "Adicionar selecionadas")) {
                            let chosen = Set(controller.suggestions.map(\.id)).subtracting(skipped)
                            controller.accept(chosen)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(Set(controller.suggestions.map(\.id)).isSubset(of: skipped))
                    }
                } footer: {
                    Text(
                        L.t(
                            "From your project folders, or from words you fixed after dictating. Nothing joins the vocabulary until you add it.",
                            "Vindas das suas pastas de projeto ou de palavras que você corrigiu depois de ditar. Nada entra no vocabulário sem você adicionar.")
                    )
                }
            }
            Section {
                HStack {
                    TextField(L.t("Add a word or name", "Adicionar palavra ou nome"), text: $term, prompt: Text("Claude Code"))
                        .onSubmit(addTerm)
                    Button(L.t("Add", "Adicionar"), action: addTerm).disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(controller.settings.vocabulary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            controller.settings.vocabulary.removeAll { $0 == word }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel(L.t("Remove", "Remover"))
                    }
                }
            } header: {
                Text(L.t("Words", "Palavras"))
            } footer: {
                Text(
                    L.t(
                        "Names and terms Legato should spell your way. When the transcript comes close, it is corrected to match. To get suggestions from your project folders, run /legato-vocabulary in Claude Code.",
                        "Nomes e termos que o Legato deve escrever do seu jeito. Quando a transcrição chega perto, ela é corrigida. Para receber sugestões das suas pastas de projeto, rode /legato-vocabulary no Claude Code.")
                )
            }
            Section {
                HStack {
                    TextField(L.t("When I say", "Quando eu disser"), text: $from, prompt: Text("meu email"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField(L.t("Write", "Escrever"), text: $to, prompt: Text("nome@exemplo.com")).onSubmit(addRule)
                    Button(L.t("Add", "Adicionar"), action: addRule)
                        .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty || to.isEmpty)
                }
                .labelsHidden()
                ForEach(controller.settings.replacements) { rule in
                    HStack {
                        Text(rule.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(rule.to)
                        Spacer()
                        Button {
                            controller.settings.replacements.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel(L.t("Remove", "Remover"))
                    }
                }
            } header: {
                Text(L.t("Replacements", "Substituições"))
            }
            Section {
                Toggle(
                    L.t("Learn from my corrections", "Aprender com as minhas correções"),
                    isOn: $controller.settings.learnFromCorrections)
            } footer: {
                Text(
                    L.t(
                        "For a minute after each dictation, Legato rereads the text field. If you retype a word into a name or term, it is suggested here. Nothing is stored or sent besides the suggestion.",
                        "Por um minuto depois de cada ditado, o Legato relê o campo de texto. Se você trocar uma palavra por um nome ou termo, ele aparece aqui como sugestão. Nada é guardado ou enviado além da sugestão.")
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.reloadSuggestions() }
        .onReceive(refresh) { _ in controller.reloadSuggestions() }
    }

    private func detail(_ suggestion: Suggestion) -> String {
        var parts: [String] = []
        if !suggestion.heard.isEmpty {
            let forms = suggestion.heard.map { "\u{201C}\($0.text)\u{201D}" }.joined(separator: ", ")
            parts.append(L.t("Heard as \(forms)", "Ouvido como \(forms)"))
        }
        if let note = suggestion.note, !note.isEmpty { parts.append(note) }
        parts.append(suggestion.source)
        return parts.joined(separator: "  ·  ")
    }

    private func addTerm() {
        let value = term.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !controller.settings.vocabulary.contains(value) else { return }
        controller.settings.vocabulary.append(value)
        term = ""
    }

    private func addRule() {
        let key = from.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !to.isEmpty else { return }
        controller.settings.replacements.append(Replacement(from: key, to: to))
        from = ""
        to = ""
    }
}

// MARK: History

private struct HistoryTab: View {
    @ObservedObject var controller: Controller
    @State private var player: AVAudioPlayer?

    var body: some View {
        VStack(spacing: 0) {
            if controller.entries.isEmpty {
                ContentUnavailableView(
                    L.t("Nothing dictated yet", "Nenhum ditado ainda"), systemImage: "waveform",
                    description: Text(L.t("Your dictations show up here, with their audio.", "Seus ditados aparecem aqui, com o áudio.")))
            } else {
                List(controller.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            if controller.inFlight.contains(entry.id) {
                                Text(L.t("Transcribing…", "Transcrevendo…")).foregroundStyle(.secondary)
                            } else if entry.status == .failed {
                                Label(entry.error ?? L.t("Failed", "Falhou"), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            } else {
                                Text(entry.text).lineLimit(3).textSelection(.enabled)
                            }
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened))  ·  \(Int(entry.duration.rounded()))s  ·  \(entry.engine)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.status == .done {
                            icon("doc.on.doc", L.t("Copy", "Copiar")) { Inserter.copy(entry.text) }
                        }
                        if let url = controller.audioURL(entry.id), !controller.inFlight.contains(entry.id) {
                            icon("play", L.t("Play", "Ouvir")) {
                                player = try? AVAudioPlayer(contentsOf: url)
                                player?.play()
                            }
                            icon("arrow.clockwise", L.t("Transcribe again", "Transcrever de novo")) {
                                controller.retry(entry.id, paste: false)
                            }
                        }
                        icon("trash", L.t("Delete", "Apagar")) { controller.delete(entry.id) }
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Picker(L.t("Keep", "Guardar"), selection: $controller.settings.historyLimit) {
                    Text(L.t("Last 20", "Últimos 20")).tag(20)
                    Text(L.t("Last 100", "Últimos 100")).tag(100)
                    Text(L.t("Last 1000", "Últimos 1000")).tag(1000)
                }
                .frame(width: 220)
                Spacer()
                Button(L.t("Show in Finder", "Mostrar no Finder")) { NSWorkspace.shared.open(controller.recordingsFolder) }
                Button(L.t("Clear", "Limpar"), role: .destructive) { controller.clearHistory() }
                    .disabled(controller.entries.isEmpty)
            }
            .padding(12)
        }
    }

    private func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}
