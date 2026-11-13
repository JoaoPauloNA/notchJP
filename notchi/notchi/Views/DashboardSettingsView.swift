import Security
import SwiftUI
import ApplicationServices

struct DashboardSettingsView: View {
    @ObservedObject var state: NotchState
    @AppStorage(AppLanguage.key) private var language = "pt-BR"
    @State private var search = ""
    @AppStorage("njp.liquidGlass") private var liquidGlass = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selection = SettingsSection.initial
    @AppStorage(NJPSettings.accentIndexKey) private var accentIndex = 0

    enum SettingsSection: String, CaseIterable, Identifiable {
        case appearance, panel, displays, accounts, agents, dictation, air, tv, diagnostics, about
        var id: Self { self }

        static var initial: SettingsSection {
            #if DEBUG
            if let flag = CommandLine.arguments.firstIndex(of: "--preview-section"),
               CommandLine.arguments.count > flag + 1,
               let section = SettingsSection(rawValue: CommandLine.arguments[flag + 1]) { return section }
            #endif
            return .panel
        }

        var title: String {
            switch self {
            case .appearance: AppLanguage.text("Aparência")
            case .panel: AppLanguage.text("Painel")
            case .displays: AppLanguage.text("Telas")
            case .accounts: AppLanguage.text("Contas e APIs")
            case .agents: AppLanguage.text("Agentes")
            case .dictation: AppLanguage.text("Ditado")
            case .air: AppLanguage.text("Ar-condicionado")
            case .tv: "TV LG"
            case .diagnostics: AppLanguage.text("Diagnóstico")
            case .about: AppLanguage.text("Sobre")
            }
        }
        var symbol: String {
            switch self {
            case .appearance: "paintpalette"
            case .panel: "rectangle.topthird.inset.filled"
            case .displays: "display"
            case .accounts: "person.crop.circle"
            case .agents: "terminal"
            case .dictation: "mic"
            case .air: "air.conditioner.horizontal"
            case .tv: "tv"
            case .diagnostics: "stethoscope"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    NotchJPMark(size: 32)
                    HStack(spacing: 0) {
                        Text("notch").font(.system(size: 20, weight: .regular))
                        Text("JP").font(.system(size: 20, weight: .heavy)).foregroundStyle(NJP.accent)
                    }
                }
                .padding(.bottom, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("notchJP")
                TextField(AppLanguage.text("Buscar ajuste"), text: $search).textFieldStyle(.roundedBorder).padding(.bottom, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(settingsGroups.enumerated()), id: \.offset) { _, group in
                            let sections = group.1.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
                            if !sections.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.0).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 10)
                                    ForEach(sections) { section in settingsButton(section) }
                                }
                            }
                        }
                    }
                }
                Spacer()
                Text("notchJP \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(18).frame(width: 230)
            .background { if !reduceTransparency { SettingsSidebarMaterial() } else { Color(nsColor: .controlBackgroundColor) } }
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(selection.title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(liquidGlass && !reduceTransparency ? AppLanguage.text("Liquid Glass ligado") : AppLanguage.text("Material sólido")).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).frame(height: 52)
                Divider()
            ScrollView {
                switch selection {
                case .appearance: NJPAppearanceSettingsView()
                case .panel: NJPPanelSettingsView()
                case .displays: DisplayResolutionSettingsView()
                case .accounts: accounts
                case .agents: NJPAgentsSettingsView()
                case .dictation: NJPDictationSettingsView()
                case .air: ACAccountSettingsView(controller: state.airController)
                case .tv: ResidentialTVSettingsView(controller: state.tvController)
                case .diagnostics: AppDiagnosticsView(state: state)
                case .about: NJPAboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDisplayResolutionSettings)) { _ in selection = .displays }
        .frame(width: 860, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .tint(NJP.accent)
        .environment(\.locale, AppLanguage.locale)
        .id(language)
        .navigationTitle(AppLanguage.text("Configurações do notchJP"))
    }

    private var settingsGroups: [(String, [SettingsSection])] {
        [(AppLanguage.text("Painel"), [.appearance, .panel, .displays]), (AppLanguage.text("Casa"), [.air, .tv]),
         (AppLanguage.text("Integrações"), [.accounts, .agents, .dictation]), (AppLanguage.text("Aplicativo"), [.diagnostics, .about])]
    }
    private func settingsButton(_ section: SettingsSection) -> some View {
        Button { selection = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).frame(width: 22)
                Text(section.title)
                Spacer(minLength: 0)
                if section == .air { ACSettingsConnection(controller: state.airController) }
                if section == .tv { TVSettingsConnection(controller: state.tvController) }
            }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(height: 38)
                .foregroundStyle(selection == section ? Color.white : Color.primary)
                .background(selection == section ? NJP.accent : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityIdentifier("settings-" + section.rawValue)
            .accessibilityAddTraits(selection == section ? .isSelected : [])
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(AppLanguage.text("Contas e APIs")).font(.title2.weight(.semibold))
            Text(AppLanguage.text("Gerencie as contas e chaves usadas para consultar seus gastos e saldos."))
                .font(.callout).foregroundStyle(.secondary)
            OpenAICreditSettingsCard(state: state)
            ForEach(DashboardAPIProvider.allCases) { provider in
                DashboardAPISettingsCard(provider: provider, state: state)
            }
            Text(AppLanguage.text("As chaves são guardadas no Chaves do macOS. Para trocar uma chave, preencha o campo e salve."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(AppLanguage.text("Contas dos assistentes")).font(.headline)
            Text(AppLanguage.text("Codex, Claude e AGY usam as contas já conectadas nos respectivos aplicativos ou CLIs. Para mudar a conta de uma cota, faça a troca no assistente correspondente."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum DashboardAPIProvider: String, CaseIterable, Identifiable {
    case router, runpod
    var id: Self { self }
    var title: String {
        switch self {
        case .router: "OpenRouter"
        case .runpod: "Runpod"
        }
    }
    var keyPlaceholder: String {
        switch self {
        case .router: AppLanguage.text("Chave de gerenciamento")
        case .runpod: AppLanguage.text("Chave da API")
        }
    }
    var service: String {
        switch self {
        case .router: routerKeyService
        case .runpod: runpodKeyService
        }
    }
    var keyAccount: String {
        switch self {
        case .router: "management"
        case .runpod: "api"
        }
    }
    var labelPreference: String {
        switch self {
        case .router: "openRouterAccountLabel"
        case .runpod: "runpodAccountLabel"
        }
    }

    func label(in state: NotchState) -> String {
        switch self {
        case .router: state.routerAccount
        case .runpod: state.runpodAccount
        }
    }

    func status(in state: NotchState) -> String {
        switch self {
        case .router: state.routerStatus
        case .runpod: state.runpodStatus
        }
    }

    func save(label: String, key: String, state: NotchState) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: keyAccount]
        let value: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        let result = updated == errSecItemNotFound
            ? SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil) : updated
        guard result == errSecSuccess else { return result }
        UserDefaults.standard.set(label, forKey: labelPreference)
        switch self {
        case .router:
            state.routerAccount = label; state.routerBalance = nil; state.routerStatus = "Consultando..."
            state.routerBalanceStale = false
        case .runpod:
            state.runpodAccount = label; state.runpodBalance = nil; state.runpodStatus = "Consultando..."
        }
        return result
    }

    func refresh(_ state: NotchState) async {
        switch self {
        case .router: await refreshRouter(state)
        case .runpod: await refreshRunpod(state)
        }
    }
}

private struct DashboardAPISettingsCard: View {
    let provider: DashboardAPIProvider
    @ObservedObject var state: NotchState
    @State private var label = ""
    @State private var key = ""
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.title).font(.headline)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Text(provider.status(in: state)).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Nome ou e-mail da conta", text: $label)
                .accessibilityLabel("Conta " + provider.title)
            SecureField(provider.keyPlaceholder, text: $key)
                .accessibilityLabel("Chave " + provider.title)
            if provider == .router {
                Link(AppLanguage.text("Abrir chaves de gerenciamento"), destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
                    .font(.caption)
            }
            HStack {
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
                else if !provider.label(in: state).isEmpty {
                    Text("Conta salva: " + provider.label(in: state)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLanguage.text("Autorizar chave salva")) {
                    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: provider.service, kSecAttrAccount as String: provider.keyAccount,
                        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
                    var result: CFTypeRef?
                    let status = SecItemCopyMatching(KeychainAccessPolicy.query(query, allowInteraction: true) as CFDictionary, &result)
                    if status == errSecSuccess { saveError = nil; Task { await provider.refresh(state) } }
                    else { saveError = "Não foi possível autorizar a chave salva (\(status))." }
                }.disabled(saving)
                Button(AppLanguage.text("Salvar")) { save() }
                    .disabled(saving || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .background(NJP.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { label = provider.label(in: state) }
    }

    private func save() {
        if provider == .router, !key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-or-") {
            saveError = "Use uma chave de gerenciamento do OpenRouter."
            return
        }
        let result = provider.save(label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                   key: key.trimmingCharacters(in: .whitespacesAndNewlines), state: state)
        guard result == errSecSuccess else {
            saveError = "Não foi possível salvar no Chaves do macOS."
            return
        }
        key = ""
        saveError = nil
        saving = true
        Task {
            defer { saving = false }
            await provider.refresh(state)
        }
    }
}

private struct OpenAICreditSettingsCard: View {
    @ObservedObject var state: NotchState
    @State private var balance = OpenAICreditBalanceService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLanguage.text("OpenAI · saldo de créditos")).font(.headline)
            Text(AppLanguage.text("Lê o saldo exibido na página da OpenAI selecionada no Safari. A chave de API do projeto não é usada nesta consulta."))
                .font(.callout).foregroundStyle(.secondary)
            TextField(AppLanguage.text("Nome da organização"), text: $state.openAIAccount)
                .textFieldStyle(.roundedBorder)
                .onChange(of: state.openAIAccount) { _, label in
                    UserDefaults.standard.set(label, forKey: "openAIOrganizationLabel")
                }
            if let snapshot = balance.snapshot {
                HStack {
                    Text(snapshot.balance, format: .currency(code: "USD")).font(.title3.weight(.semibold))
                    Spacer()
                    Text(snapshot.observedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(balance.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppLanguage.text("Para ler o valor, o macOS exige Acessibilidade para o notchJP. O app consulta apenas o saldo na página da OpenAI, sem ler chaves, cookies ou senhas."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(AppLanguage.text("Abrir painel no Safari")) {
                    guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
                    NSWorkspace.shared.open([URL(string: "https://platform.openai.com/home")!],
                                            withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
                }
                Spacer()
                if balance.isRefreshing { ProgressView().controlSize(.small) }
                Button(balance.enabled ? AppLanguage.text("Atualizar saldo") : AppLanguage.text("Conectar leitura do saldo")) {
                    balance.enable()
                    if !AXIsProcessTrusted() {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Task { await balance.refresh() }
                }.disabled(balance.isRefreshing)
            }
            if balance.enabled {
                Button(AppLanguage.text("Desativar leitura do Safari")) { balance.disable() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(NJP.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await balance.refresh() } }
        }
    }
}

private struct ACSettingsConnection: View {
    @ObservedObject var controller: ACController
    var body: some View { Circle().fill(controller.state != nil && controller.error == nil ? Color.green : .clear).frame(width: 6, height: 6).accessibilityLabel(controller.state == nil ? AppLanguage.text("Desconectado") : AppLanguage.text("Conectado")) }
}
private struct TVSettingsConnection: View {
    @ObservedObject var controller: LGTVController
    var body: some View { Circle().fill(controller.connected ? Color.green : .clear).frame(width: 6, height: 6).accessibilityLabel(controller.connected ? AppLanguage.text("Conectada") : AppLanguage.text("Desconectada")) }
}
private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar; view.blendingMode = .behindWindow; view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
