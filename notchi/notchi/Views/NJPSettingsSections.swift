import SwiftUI

private func tilde(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

private struct SettingsRow<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(NJP.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SettingsHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private func notifySettingsChanged() {
    NotificationCenter.default.post(name: .njpSettingsChanged, object: nil)
}

// MARK: Aparência

struct NJPAppearanceSettingsView: View {
    @AppStorage("njp.glassContrast") private var glassContrast = false
    @AppStorage("njp.liquidGlass") private var liquidGlass = false
    @AppStorage(NJPSettings.accentIndexKey) private var accentIndex = 0

    private func materialPreview(_ title: String, glass: Bool) -> some View {
        Button { liquidGlass = glass } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    LinearGradient(colors: [.indigo, .orange.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    HStack(spacing: 5) {
                        VStack(spacing: 7) { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.3)).frame(width: 12, height: 12) } }.frame(width: 26)
                        RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.12)).padding(8)
                    }.frame(width: 110, height: 100).background(.black.opacity(glass ? 0.55 : 0.95), in: UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12))
                }.frame(height: 125).clipShape(RoundedRectangle(cornerRadius: 12))
                HStack { Text(title); Spacer(); Image(systemName: liquidGlass == glass ? "checkmark.circle.fill" : "circle") }
            }.font(.system(size: 12, weight: .medium)).padding(10)
                .background(NJP.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(liquidGlass == glass ? NJP.accent : .white.opacity(0.1)))
        }.buttonStyle(.plain).accessibilityAddTraits(liquidGlass == glass ? .isSelected : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeader(title: "Aparência", subtitle: "A cor de destaque vale para o painel do notch e para estas janelas.")
            if #available(macOS 26.0, *) {
                HStack(spacing: 12) {
                    materialPreview("Sólido", glass: false)
                    materialPreview("Liquid Glass", glass: true)
                }
                Toggle("Liquid Glass", isOn: $liquidGlass)
                Toggle("Contraste reforçado no vidro", isOn: $glassContrast).disabled(!liquidGlass)
                Text("Vidro nativo na navegação e fundo translúcido escuro para leitura. Desligue para usar o preto sólido. Respeita Reduzir transparência do macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("COR DE DESTAQUE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(Array(NJPSettings.accentPalette.enumerated()), id: \.offset) { index, item in
                    Button { accentIndex = index } label: {
                        Circle().fill(item.color).frame(width: 36, height: 36)
                            .overlay { if accentIndex == index { Circle().stroke(.white, lineWidth: 2).padding(-4) } }
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(accentIndex == index ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
            HStack(spacing: 10) {
                NotchJPMark(size: 28)
                Image(systemName: "music.note").frame(width: 34, height: 28).background(NJP.accent, in: Capsule())
                Text("Hoje").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6).background(NJP.accent, in: Capsule())
                Circle().fill(NJP.accent).frame(width: 28, height: 28)
                    .overlay { Text("6").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
            }
            .padding(16)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Prévia da cor de destaque")
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Painel

struct NJPPanelSettingsView: View {
    @AppStorage(NJPSettings.expandOnHoverKey) private var expandOnHover = true
    @AppStorage(NJPSettings.hoverDelayKey) private var hoverDelay = 0.3
    @AppStorage(NJPSettings.rememberPageKey) private var rememberPage = true
    @AppStorage(NJPSettings.swipeTabsKey) private var swipeTabs = true
    @AppStorage(NJPSettings.shortcutEnabledKey) private var shortcutEnabled = true
    @AppStorage(NJPSettings.eventAlertKey) private var eventAlert = true
    @AppStorage(NJPSettings.diskAlertKey) private var diskAlert = true
    @AppStorage(NJPSettings.agentAlertKey) private var agentAlert = true
    @AppStorage(NJPSettings.nowPlayingAlertKey) private var nowPlayingAlert = true
    @AppStorage(NJPSettings.privacyAlertKey) private var privacyAlert = true
    @AppStorage(NJPSettings.clipboardHistoryKey) private var clipboardHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(title: "Painel", subtitle: "Como o painel abre e o que o notch fechado avisa.")
                .padding(.bottom, 8)
            LaunchAtLoginSetting()
            SettingsRow(title: "Abrir ao passar o mouse", hint: "Desligado, só o atalho abre o painel.") {
                Toggle("", isOn: $expandOnHover).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Atraso para abrir") {
                Picker("", selection: $hoverDelay) {
                    Text("Rápido").tag(0.15)
                    Text("Normal").tag(0.3)
                    Text("Lento").tag(0.6)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 210)
                .disabled(!expandOnHover)
            }
            SettingsRow(title: "Atalho global", hint: "\(AppSettings.panelToggleShortcut.displayName) abre e fecha o painel.") {
                Toggle("", isOn: $shortcutEnabled).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Lembrar a última aba") {
                Toggle("", isOn: $rememberPage).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Trocar de aba com dois dedos", hint: "Deslize para os lados no trackpad com o painel aberto.") {
                Toggle("", isOn: $swipeTabs).labelsHidden().toggleStyle(.switch)
            }
            PanelTabsSettings()
            Text("AVISOS COM O NOTCH FECHADO").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 10)
            SettingsRow(title: "Próximo compromisso", hint: "15 minutos antes de começar.") {
                Toggle("", isOn: $eventAlert).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Pouco espaço em disco", hint: "Abaixo de \(SystemHealthService.lowDiskThresholdGB) GB livres.") {
                Toggle("", isOn: $diskAlert).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Sessões do Claude Code e do Codex", hint: "Pede aprovação ou terminou. Exige ativar os hooks em Agentes.") {
                Toggle("", isOn: $agentAlert).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Música tocando", hint: "Ondas e o título da faixa ao lado do notch.") {
                Toggle("", isOn: $nowPlayingAlert).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Microfone ou câmera em uso", hint: "Ícone vermelho ao lado do notch enquanto algum app usa.") {
                Toggle("", isOn: $privacyAlert).labelsHidden().toggleStyle(.switch)
            }
            Text("PRIVACIDADE").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 10)
            SettingsRow(title: "Histórico da área de transferência", hint: "Guarda os últimos textos copiados só na memória e ignora gerenciadores de senha.") {
                Toggle("", isOn: $clipboardHistory).labelsHidden().toggleStyle(.switch)
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: shortcutEnabled) { _, _ in notifySettingsChanged() }
        .onChange(of: agentAlert) { _, _ in notifySettingsChanged() }
        .onChange(of: clipboardHistory) { _, _ in notifySettingsChanged() }
    }
}

// MARK: Agentes

struct NJPAgentsSettingsView: View {
    @ObservedObject private var monitor = AgentActivityMonitor.shared
    @State private var claudeInstalled = HookInstaller.isInstalled()
    @State private var codexInstalled = FileManager.default.fileExists(atPath: CodexHookInstaller.hookScriptURL.path)
    @State private var devinInstalled = DevinHookInstaller.isInstalled()
    @State private var agyInstalled = AgyHookInstaller.isInstalled()
    @State private var message: String?

    var body: some View {
        let claude = ClaudeConfigDirectoryResolver.resolve()
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(title: "Agentes", subtitle: "O notch avisa quando o Claude Code ou o Codex pede aprovação ou termina. Isso só funciona com hooks instalados, e nada é alterado até você ativar.")
                .padding(.bottom, 8)
            SettingsRow(
                title: "Claude Code",
                hint: "Escreve \(tilde(claude.hookScriptURL)) e registra os eventos em \(tilde(claude.settingsURL)). Remover desfaz as duas coisas."
            ) {
                Button(claudeInstalled ? "Remover" : "Ativar") { toggleClaude() }
            }
            SettingsRow(
                title: "Codex",
                hint: "Escreve \(tilde(CodexHookInstaller.hookScriptURL)), registra os eventos em \(tilde(CodexHookInstaller.hooksJSONURL)) e liga o recurso de hooks em \(tilde(CodexHookInstaller.configURL))."
            ) {
                Button(codexInstalled ? "Remover" : "Ativar") { toggleCodex() }
            }
            SettingsRow(
                title: "Devin",
                hint: "Escreve \(tilde(DevinHookInstaller.hookScriptURL)) e registra os eventos em \(tilde(DevinHookInstaller.configURL)). Remover desfaz."
            ) {
                Button(devinInstalled ? "Remover" : "Ativar") { toggleDevin() }
            }
            SettingsRow(
                title: "AGY (Antigravity)",
                hint: "Escreve \(tilde(AgyHookInstaller.hookScriptURL)) e acrescenta a entrada \"notchjp\" em \(tilde(AgyHookInstaller.hooksJSONURL)), sem mexer nas que já existem (como a do ai-memory). Guarda uma cópia do original. Mostra trabalhando e pronto; o AGY não tem evento de aprovação."
            ) {
                Button(agyInstalled ? "Remover" : "Ativar") { toggleAgy() }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(NJP.warn)
            }
            Text("SESSÕES VISTAS AGORA").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 10)
            if monitor.sessions.isEmpty {
                Text("Nenhuma sessão ativa. Depois de ativar, abra o Claude Code ou o Codex e ela aparece aqui.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.sessions) { session in
                    SettingsRow(title: session.project, hint: session.agent) {
                        Text(label(for: session.phase)).font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(color(for: session.phase).opacity(0.18), in: Capsule())
                            .foregroundStyle(color(for: session.phase))
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(for phase: AgentSessionSnapshot.Phase) -> String {
        switch phase {
        case .working: "Trabalhando"
        case .needsApproval: "Precisa de você"
        case .done: "Pronto"
        }
    }

    private func color(for phase: AgentSessionSnapshot.Phase) -> Color {
        switch phase {
        case .working: NJP.accent
        case .needsApproval: NJP.warn
        case .done: NJP.good
        }
    }

    private func toggleClaude() {
        message = nil
        if claudeInstalled {
            HookInstaller.uninstall()
        } else if !HookInstaller.installIfNeeded() {
            message = "Não encontrei a pasta de configuração do Claude Code neste Mac."
        }
        claudeInstalled = HookInstaller.isInstalled()
        notifySettingsChanged()
    }

    private func toggleAgy() {
        message = nil
        if agyInstalled {
            AgyHookInstaller.uninstall()
        } else if !AgyHookInstaller.installIfNeeded() {
            message = "Não consegui instalar os hooks do AGY. Confira se a pasta ~/.gemini existe e se hooks.json é um JSON válido."
        }
        agyInstalled = AgyHookInstaller.isInstalled()
        notifySettingsChanged()
    }

    private func toggleDevin() {
        message = nil
        if devinInstalled {
            DevinHookInstaller.uninstall()
        } else if !DevinHookInstaller.installIfNeeded() {
            message = "Não consegui instalar os hooks do Devin. Confira se a pasta do Devin existe."
        }
        devinInstalled = DevinHookInstaller.isInstalled()
        notifySettingsChanged()
    }

    private func toggleCodex() {
        message = nil
        if codexInstalled {
            CodexHookInstaller.uninstall()
        } else if !CodexHookInstaller.installIfNeeded() {
            message = "Não consegui instalar os hooks do Codex. Confira se a pasta ~/.codex existe."
        }
        codexInstalled = FileManager.default.fileExists(atPath: CodexHookInstaller.hookScriptURL.path)
        notifySettingsChanged()
    }
}

// MARK: Sobre

struct NJPAboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Versão \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            NotchJPMark(size: 96).padding(.top, 20)
            HStack(spacing: 0) {
                Text("notch").font(.system(size: 30, weight: .regular))
                Text("JP").font(.system(size: 30, weight: .heavy)).foregroundStyle(NJP.accent)
            }
            Text(version + " · Edição Pública").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Código aberto").font(.system(size: 13, weight: .bold))
                Text("O notchJP é baseado no Notchi, de Ruban, e segue a mesma licença GNU GPL v3.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(NJP.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                Text("Edição pública · atualização manual").font(.headline)
                Text("Esta edição não consulta servidores de atualização. Para atualizar, obtenha o fonte no GitHub e compile novamente.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Abrir notchJP no GitHub", destination: URL(string: "https://github.com/JoaoPauloNA/notchJP")!)
            }
            .padding(14).background(NJP.surface, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                Button("Reiniciar notchJP") { AppControl.restart() }
                    .help("Fecha e abre o app de novo")
                Button("Sair") { AppControl.quit() }
                    .help("Fecha o notchJP; abra de novo por /Applications")
            }
            Button("Recompilar e instalar…") { LocalBuilder.confirmAndRun() }
                .help("Compila este projeto com o Xcode, troca o app em /Applications e reabre")
            HStack(spacing: 10) {
                Link("Projeto original", destination: URL(string: "https://github.com/sk-ruban/notchi")!)
                Link("Licença GPL v3", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(28).frame(maxWidth: .infinity)
    }
}

// MARK: Ditado

struct NJPDictationSettingsView: View {
    @ObservedObject private var model = DictationController.shared.model
    @AppStorage(NJPSettings.dictationEnabledKey) private var enabled = false
    @State private var key = ""
    @State private var capturing = false
    @State private var captureError: String?
    @State private var monitor: Any?
    private let languages = [("pt-BR", "Português (Brasil)"), ("en-US", "English (US)"), ("es-ES", "Español")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(title: "Ditado", subtitle: "Fale com um atalho e o texto é colado no campo onde você estava. Inclui o antigo BlabberType.")
                .padding(.bottom, 8)
            SettingsRow(title: "Ativar o ditado no notch",
                        hint: "Se o BlabberType estiver aberto, feche-o antes: os dois usariam o mesmo atalho e gravariam juntos.") {
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
            }
            if enabled {
                SettingsRow(title: "Atalho", hint: capturing ? "Pressione a combinação (Esc cancela)" : "Segure para ditar; toque duas vezes para mãos livres.") {
                    HStack(spacing: 8) {
                        Text(capturing ? "…" : model.shortcutStatus).font(.system(size: 12, weight: .semibold))
                        Button(capturing ? "Cancelar" : "Alterar…") { capturing ? stopCapture() : startCapture() }
                    }
                }
                if let captureError { Text(captureError).font(.caption).foregroundStyle(NJP.warn) }
                SettingsRow(title: "Conexão de voz") {
                    Picker("", selection: $model.settings.provider) {
                        ForEach(DictationProvider.selectable) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190)
                }
                SettingsRow(title: "Idioma") {
                    Picker("", selection: $model.settings.language) {
                        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().frame(width: 190)
                }
                SettingsRow(title: "Seu vocabulário", hint: "Nomes e termos que o ditado costuma errar, separados por vírgula. Vale para o reconhecimento novo do macOS.") {
                    TextField("notchJP, Hostinger, TCL", text: vocabularyText)
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                }
                if model.settings.provider == .whisper {
                    SettingsRow(title: "Servidor Whisper", hint: "whisper-server já em execução neste Mac.") {
                        TextField("http://127.0.0.1:8080/inference", text: $model.settings.whisperEndpoint)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                }
                if model.settings.provider == .api {
                    SettingsRow(title: "Endereço da API", hint: "O áudio sai do Mac neste modo.") {
                        TextField("https://…/audio/transcriptions", text: $model.settings.apiEndpoint)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    SettingsRow(title: "Modelo") {
                        TextField("whisper-1", text: $model.settings.apiModel).textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                    SettingsRow(title: "Chave da API", hint: "Fica no Chaves do macOS. Deixe vazio para manter a salva.") {
                        HStack {
                            SecureField("sk-…", text: $key).textFieldStyle(.roundedBorder).frame(width: 150)
                            Button("Salvar") { model.apiKey = key; model.saveKey(); key = "" }.disabled(key.isEmpty)
                        }
                    }
                }
                if model.settings.provider == .analyzer {
                    SettingsRow(title: "Mostrar o texto enquanto falo", hint: "As palavras aparecem em Ferramentas > Ditado durante a gravação.") {
                        Toggle("", isOn: $model.settings.liveText).labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingsRow(title: "Colar no campo automaticamente", hint: model.accessibilityGranted ? "Acessibilidade permitida." : "Precisa da permissão de Acessibilidade.") {
                    HStack {
                        if !model.accessibilityGranted { Button("Permitir") { model.allowAutomaticPaste() } }
                        Toggle("", isOn: $model.settings.autoPaste).labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingsRow(title: "Guardar histórico", hint: "Os últimos 100 ditados, neste Mac.") {
                    HStack {
                        if !model.history.isEmpty { Button("Limpar") { model.clearHistory() } }
                        Toggle("", isOn: $model.settings.keepHistory).labelsHidden().toggleStyle(.switch)
                    }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(NJP.warn) }
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: enabled) { _, _ in notifySettingsChanged() }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .onAppear { model.refreshPastePermission() }
        .onDisappear { stopCapture() }
    }

    private var vocabularyText: Binding<String> {
        Binding(
            get: { model.settings.vocabulary.joined(separator: ", ") },
            set: { model.settings.vocabulary = Self.parseVocabulary($0) }
        )
    }

    /// "a, b ,, a" -> ["a", "b"]
    static func parseVocabulary(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func startCapture() {
        capturing = true
        captureError = nil
        model.isEditingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopCapture(); return nil }
            let flags = event.modifierFlags
            var modifiers: UInt32 = 0
            if flags.contains(.control) { modifiers |= DictationShortcut.control }
            if flags.contains(.option) { modifiers |= DictationShortcut.option }
            if flags.contains(.shift) { modifiers |= DictationShortcut.shift }
            if flags.contains(.command) { modifiers |= DictationShortcut.command }
            let shortcut = DictationShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            do {
                try model.checkShortcut?(shortcut)
                try model.changeShortcut?(shortcut)
                stopCapture()
            } catch { captureError = error.localizedDescription }
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
        model.isEditingShortcut = false
    }
}
