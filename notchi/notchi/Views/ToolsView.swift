import SwiftUI
import UniformTypeIdentifiers

/// Reads file URLs out of drag-and-drop providers.
func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
}

/// AppLanguage.text("Ferramentas") page: timer, project shortcuts, file shelf, clipboard history and reminders.
struct ToolsView: View {
    @Environment(\.panelComposition) private var composition
    var home: HomeAutomation? = nil
    @AppStorage(NJPSettings.toolsSectionKey) private var section = 0

    private let sections: [(title: String, symbol: String)] = [
        (AppLanguage.text("Cronômetro"), "timer"), ("Atalhos", "folder"), ("Bandeja", "tray.and.arrow.down"),
        ("Copiados", "doc.on.clipboard"), (AppLanguage.text("Lembretes"), "checklist"), (AppLanguage.text("Ditado"), "mic"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, item in
                    Button { section = index } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(section == index ? NJP.accent : NJP.surface, in: Capsule())
                            .foregroundStyle(section == index ? Color.white : .white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == index ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            }
            Group {
                switch section {
                case 0: TimerSection(home: home)
                case 1: ShortcutsSection()
                case 2: ShelfSection()
                case 3: ClipboardSection()
                case 4: RemindersSection()
                default: DictationSection()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Color.primary)
        .padding(.top, 2)
    }
}

// MARK: Cronômetro

private struct TimerSection: View {
    @Environment(\.panelComposition) private var composition
    var home: HomeAutomation?
    @State private var sceneID = ""
    @ObservedObject private var timer = FocusTimerService.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .center, spacing: 20)) : AnyLayout(HStackLayout(spacing: 28))
            layout {
                NJPRing(progress: timer.progress(now: now), color: ringColor, label: FocusTimerService.format(timer.remaining(now: now)), lineWidth: 9)
                    .frame(width: 150, height: 150)
                    .overlay { if case .finished = timer.state { Text("Tempo!").font(.system(size: 13, weight: .bold)).offset(y: 30) } }
                controls
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var ringColor: Color {
        if case .finished = timer.state { return NJP.good }
        return NJP.accent
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch timer.state {
            case .idle, .finished:
                Text(AppLanguage.text("Começar um foco")).font(.system(size: 13, weight: .bold))
                if let home {
                    FocusScenePicker(home: home, sceneID: $sceneID)
                }
                let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach([15, 25, 45], id: \.self) { minutes in
                        chip("\(minutes) min") {
                            if let home { Task { await home.startFocus(minutes: minutes, sceneID: sceneID.isEmpty ? nil : sceneID) } }
                            else { timer.start(minutes: minutes) }
                        }
                    }
                    chip(AppLanguage.text("Pausa 5 min")) { timer.start(minutes: 5) }
                }
            case .running:
                HStack(spacing: 8) {
                    chip(AppLanguage.text("Pausar"), prominent: true) { timer.pause() }
                    chip("Zerar") { timer.reset() }
                }
            case .paused:
                HStack(spacing: 8) {
                    chip(AppLanguage.text("Continuar"), prominent: true) { timer.resume() }
                    chip("Zerar") { timer.reset() }
                }
            }
            Text(AppLanguage.text("O tempo aparece ao lado do notch com o painel fechado."))
                .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
        }
    }

    private func chip(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(prominent ? NJP.accent : NJP.surfaceStrong, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct FocusScenePicker: View {
    @ObservedObject var home: HomeAutomation
    @Binding var sceneID: String
    var body: some View {
        VStack(alignment: .leading) {
            Picker(AppLanguage.text("Cena ao iniciar"), selection: $sceneID) {
                Text(AppLanguage.text("Somente cronômetro")).tag("")
                ForEach(home.scenes) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 260)
            if let message = home.message { Text(message).font(.caption).foregroundStyle(NJP.warn) }
        }
    }
}

// MARK: Atalhos

private struct ShortcutsSection: View {
    @ObservedObject private var store = ProjectShortcutsStore.shared

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(store.paths, id: \.self) { path in tile(path) }
                if store.paths.count < 8 {
                    Button(action: choose) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                            Text(AppLanguage.text("Adicionar pasta")).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(Capsule().stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func tile(_ path: String) -> some View {
        Button { ProjectShortcutsStore.open(path) } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").font(.system(size: 12)).foregroundStyle(NJP.accentSoft)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 46)
            .background(NJP.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Abrir \(path) no iTerm")
        .contextMenu {
            Button(AppLanguage.text("Abrir no iTerm")) { ProjectShortcutsStore.open(path) }
            Button(AppLanguage.text("Abrir no Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button(AppLanguage.text("Abrir no Visual Studio Code")) { ProjectShortcutsStore.open(path, withBundle: "com.microsoft.VSCode") }
            Divider()
            Button(AppLanguage.text("Remover atalho")) { store.remove(path) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adicionar"
        panel.message = AppLanguage.text("Escolha as pastas dos projetos")
        if panel.runModal() == .OK { store.add(panel.urls) }
    }
}

// MARK: Bandeja

private struct ShelfSection: View {
    @ObservedObject private var store = FileShelfStore.shared
    @State private var targeted = false

    var body: some View {
        let items = store.items
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 14))
                    Text(items.isEmpty ? AppLanguage.text("Arraste arquivos para qualquer lugar do painel") : AppLanguage.text("Solte mais arquivos aqui"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.primary.opacity(targeted ? 1 : 0.6))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(targeted ? NJP.accent.opacity(0.25) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                ForEach(items, id: \.path) { url in row(url) }
            }
            .padding(.bottom, 8)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(from: providers) { store.add($0) }
            return true
        }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
            Text(url.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
            }.buttonStyle(.plain).help(AppLanguage.text("Mostrar no Finder"))
            Menu {
                Button("AirDrop") {
                    NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
                }.disabled(NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: [url]) != true)
                Button(AppLanguage.text("Copiar caminho")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                ShareLink(item: url) { Text("Compartilhar…") }
            } label: { Image(systemName: "square.and.arrow.up") }
            .menuStyle(.borderlessButton).fixedSize().help(AppLanguage.text("Compartilhar arquivo"))
            Button { store.remove(url) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }.buttonStyle(.plain).help(AppLanguage.text("Tirar da bandeja"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(NJP.surface, in: Capsule())
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(AppLanguage.text("Arraste para outro app"))
    }
}

// MARK: Copiados

private struct ClipboardSection: View {
    @ObservedObject private var history = ClipboardHistoryService.shared
    @AppStorage(NJPSettings.clipboardHistoryKey) private var enabled = false
    @State private var copied: String?

    var body: some View {
        if !enabled {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 24)).foregroundStyle(Color.primary.opacity(0.7))
                Text(AppLanguage.text("Histórico da área de transferência")).font(.system(size: 14, weight: .bold))
                Text(AppLanguage.text("Guarda os últimos textos copiados, só na memória, e ignora gerenciadores de senha."))
                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7)).multilineTextAlignment(.center)
                Button {
                    enabled = true
                    ClipboardHistoryService.shared.apply()
                } label: {
                    Text("Ativar").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8).background(NJP.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if history.items.isEmpty {
            Text(AppLanguage.text("Copie um texto e ele aparece aqui.")).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(history.items, id: \.self) { text in
                        Button {
                            history.copyBack(text)
                            copied = text
                        } label: {
                            HStack(spacing: 8) {
                                Text(text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: copied == text ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                                    .foregroundStyle(copied == text ? NJP.good : .white.opacity(0.5))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(NJP.surface, in: Capsule())
                        }
                        .buttonStyle(.plain).help(AppLanguage.text("Copiar de novo"))
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: Lembretes

private struct RemindersSection: View {
    @State private var draft = ""
    @State private var notice: String?
    private func create() {
        if let error = service.create(draft) { notice = error }
        else { draft = ""; notice = "Lembrete criado." }
    }
    @ObservedObject private var service = RemindersService.shared

    var body: some View {
        Group {
            switch service.access {
            case .unknown:
                prompt(AppLanguage.text("Conectar lembretes do Mac"), symbol: "checklist", prominent: true) { Task { await service.requestAccess() } }
            case .denied:
                prompt(AppLanguage.text("Permitir lembretes em Ajustes do Sistema"), symbol: "lock", prominent: false) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(url) }
                }
            case .granted:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Beber água em 20 minutos", text: $draft).textFieldStyle(.roundedBorder).onSubmit { create() }
                        Button("Criar") { create() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if service.items.isEmpty {
                    Text(AppLanguage.text("Nenhum lembrete para hoje.")).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 6) { ForEach(service.items) { item in row(item) } }.padding(.bottom, 8)
                    }
                }
                }
            }
        }
        .onAppear { service.refresh() }
    }

    private func row(_ item: ReminderItem) -> some View {
        HStack(spacing: 10) {
            Button { service.complete(item) } label: {
                Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(NJP.accentSoft)
            }.buttonStyle(.plain).help(AppLanguage.text("Concluir"))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(item.listName).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
            }
            Spacer(minLength: 8)
            if let due = item.due {
                Text(due.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(due < Date() ? NJP.warn : .white.opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(NJP.surface, in: Capsule())
    }

    private func prompt(_ title: String, symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(prominent ? NJP.accent : NJP.surfaceStrong, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Ditado

private struct DictationSection: View {
    @AppStorage(NJPSettings.dictationEnabledKey) private var enabled = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if enabled {
            DictationPanel()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "mic").font(.system(size: 26)).foregroundStyle(Color.primary.opacity(0.7))
                Text(AppLanguage.text("Ditado por voz")).font(.system(size: 14, weight: .bold))
                Text(AppLanguage.text("Segure um atalho, fale, e o texto é colado no campo onde você estava. Funciona no Mac ou por API."))
                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7)).multilineTextAlignment(.center)
                Button {
                    enabled = true
                    NotificationCenter.default.post(name: .njpSettingsChanged, object: nil)
                } label: {
                    Text("Ativar").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8).background(NJP.accent, in: Capsule())
                }.buttonStyle(.plain)
                Text("Se o BlabberType estiver aberto, feche-o antes de ativar.")
                    .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DictationPanel: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject private var model = DictationController.shared.model
    @State private var copied: UUID?

    var body: some View {
        let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .center, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        return layout {
            VStack(spacing: 10) {
                Button { model.toggle() } label: {
                    ZStack {
                        Circle().fill(model.isRecording ? NJP.bad : NJP.accent).frame(width: 88, height: 88)
                        if model.isProcessing {
                            ProgressView().controlSize(.regular).tint(.white)
                        } else {
                            Image(systemName: model.isRecording ? "stop.fill" : "mic.fill").font(.system(size: 30, weight: .semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(model.isRecording ? AppLanguage.text("Parar e transcrever") : AppLanguage.text("Começar a gravar"))
                if model.isRecording {
                    HStack(spacing: 2) {
                        ForEach(Array(model.levels.suffix(24).enumerated()), id: \.offset) { _, level in
                            Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: 4 + level * 22)
                        }
                    }.frame(height: 26)
                    if !model.liveText.isEmpty {
                        Text(model.liveText).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.85))
                            .lineLimit(3).multilineTextAlignment(.center).frame(width: 220)
                            .animation(.easeOut(duration: 0.15), value: model.liveText)
                    }
                } else {
                    Text(model.status).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7))
                        .multilineTextAlignment(.center).frame(width: 190)
                }
                Text("\(AppLanguage.text("Segure")) \(model.shortcutStatus) \(AppLanguage.text("para ditar"))").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                if model.settings.autoPaste, !model.accessibilityGranted {
                    Button { model.allowAutomaticPaste() } label: {
                        Text(AppLanguage.text("Permitir colagem automática")).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6).background(NJP.warn.opacity(0.25), in: Capsule())
                    }.buttonStyle(.plain)
                }
                if model.canRetry {
                    Button { model.retry() } label: {
                        Text(AppLanguage.text("Tentar de novo")).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6).background(NJP.surfaceStrong, in: Capsule())
                    }.buttonStyle(.plain)
                }
                if let error = model.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(NJP.warn).lineLimit(3).frame(width: 220)
                }
                if !model.pasteDiagnostic.isEmpty {
                    Text(model.pasteDiagnostic).font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.7))
                        .lineLimit(4).frame(width: 220).help(AppLanguage.text("Último destino da colagem"))
                }
            }
            .frame(width: 230)
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLanguage.text("Últimos ditados")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.7))
                if model.history.isEmpty {
                    Text(AppLanguage.text("Nada ainda.")).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.7))
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 6) {
                            ForEach(model.history.prefix(8)) { record in
                                Button {
                                    model.copy(record.text)
                                    copied = record.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(record.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12)).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Image(systemName: copied == record.id ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                                            .foregroundStyle(copied == record.id ? NJP.good : .white.opacity(0.5))
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(NJP.surface, in: Capsule())
                                }
                                .buttonStyle(.plain).help(AppLanguage.text("Copiar de novo"))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { model.refreshPastePermission() }
    }
}
