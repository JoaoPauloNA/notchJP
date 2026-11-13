import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

nonisolated enum AppLanguage {
    static let key = "njp.language"
    static var code: String { UserDefaults.standard.string(forKey: key) == "en" ? "en" : "pt-BR" }
    static var locale: Locale { Locale(identifier: code) }
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: ["en", "pt-BR"].compactMap { code in
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return (code, bundle)
    })
    static func text(_ key: String) -> String {
        guard let bundle = bundles[code] else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Dashboard")
    }
}

@MainActor enum AppExperience {
    static weak var home: HomeAutomation?
    private static var guideWindow: NSWindow?
    static func showGuide() {
        if let guideWindow { guideWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "notchJP"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FirstRunGuide())
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        guideWindow = window
    }
    static func finishGuide() {
        UserDefaults.standard.set(true, forKey: "njp.guideCompleted")
        guideWindow?.close(); guideWindow = nil
    }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.key) private var language = "pt-BR"
    var body: some View {
        Picker("Idioma / Language", selection: $language) {
            Text("Português (Brasil)").tag("pt-BR")
            Text("English").tag("en")
        }.onChange(of: language) { _, _ in NotificationCenter.default.post(name: .njpSettingsChanged, object: nil) }
    }
}

struct FirstRunGuide: View {
    @AppStorage(AppLanguage.key) private var language = "pt-BR"
    @State private var step = 0
    private func t(_ pt: String, _ en: String) -> String { language == "en" ? en : pt }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Bem-vindo ao notchJP", "Welcome to notchJP")).font(.largeTitle.bold())
            LanguagePicker()
            if step == 0 {
                Text(t("Escolha as abas que quer usar. As integrações são opcionais.", "Choose the tabs you want to use. Integrations are optional."))
                ScrollView { PanelTabsSettings() }
            } else {
                Text(t("Permissões quando precisar", "Permissions when you need them")).font(.title2)
                Text(t("Spotify pede Automação. O mixer pede acesso ao áudio do sistema. Calendário e Lembretes pedem acesso às respectivas listas. Ditado usa o microfone. Nenhuma permissão é solicitada por este guia.", "Spotify uses Automation. The mixer needs system audio access. Calendar and Reminders need access to their stores. Dictation uses the microphone. This guide does not request any permissions."))
                Text(t("LG: faça o pareamento com a TV ligada. TCL: conecte sua própria conta TCL Home nos Ajustes. Para voz, adicione as ações notchJP no app Atalhos do Mac.", "LG: pair while the TV is on. TCL: connect your own TCL Home account in Settings. For voice control, add notchJP actions in the Mac Shortcuts app."))
                Text(t("⌥⌘N abre o painel. Você pode reabrir este guia em Ajustes → Sobre.", "⌥⌘N opens the panel. Reopen this guide in Settings → About."))
                Spacer()
            }
            HStack {
                Button(t("Configurar depois", "Set up later")) { AppExperience.finishGuide() }
                Spacer()
                if step > 0 { Button(t(AppLanguage.text("Voltar"), "Back")) { step = 0 } }
                Button(step == 0 ? t(AppLanguage.text("Continuar"), "Continue") : t(AppLanguage.text("Concluir"), "Finish")) {
                    if step == 0 { step = 1 } else { AppExperience.finishGuide() }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 600, height: 570)
            .environment(\.locale, AppLanguage.locale)
            .id(language)
    }
}

/// Export only typed status values; never serialize errors, defaults, account/device names or URLs.
nonisolated struct AppDiagnosticReport: Codable {
    let schemaVersion: Int
    let appVersion: String
    let edition: String
    let macOS: String
    let displayCount: Int
    let mixerEnabled: Bool
    let mixerAppCount: Int
    let mixerErrorCount: Int
    let spotifyRunning: Bool
    let airDeviceCount: Int
    let airHasError: Bool
    let tvConnected: Bool
    let tvHasError: Bool
}

@MainActor enum AppDiagnostics {
    static func report(home: HomeAutomation?) -> AppDiagnosticReport {
        let mixer = AppAudioMixer.shared
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AppDiagnosticReport(schemaVersion: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            edition: Bundle.main.object(forInfoDictionaryKey: "NJPDistributionEdition") as? String == "private" ? "private" : "public",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", displayCount: NSScreen.screens.count,
            mixerEnabled: mixer.enabled, mixerAppCount: mixer.apps.count, mixerErrorCount: mixer.errors.count,
            spotifyRunning: NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" },
            airDeviceCount: home?.air.devices.count ?? 0, airHasError: home?.air.error != nil,
            tvConnected: home?.tv.connected ?? false, tvHasError: home?.tv.error != nil)
    }
    static func encoded(_ report: AppDiagnosticReport) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}

struct AppDiagnosticsView: View {
    @ObservedObject var state: NotchState
    @State private var report: AppDiagnosticReport?
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLanguage.text("Diagnóstico")).font(.title2.bold())
            Text(AppLanguage.text("O relatório inclui apenas versão, contagens e estados. Não inclui contas, tokens, nomes de aparelhos, endereços ou conteúdo de prompts.")).font(.callout)
            if let report {
                LabeledContent("Spotify", value: report.spotifyRunning ? AppLanguage.text("Aberto") : AppLanguage.text("Fechado"))
                LabeledContent("Mixer", value: report.mixerEnabled ? AppLanguage.text("Ativo") : AppLanguage.text("Desligado"))
                LabeledContent(AppLanguage.text("Falhas no mixer"), value: "\(report.mixerErrorCount)")
                LabeledContent("TV LG", value: report.tvConnected ? AppLanguage.text("Conectada") : AppLanguage.text("Desconectada"))
                LabeledContent(AppLanguage.text("Ares cadastrados"), value: "\(report.airDeviceCount)")
                LabeledContent(AppLanguage.text("Telas"), value: "\(report.displayCount)")
            }
            HStack {
                Button(AppLanguage.text("Atualizar estado")) { refresh() }
                Button(AppLanguage.text("Reconectar áudio")) { AppAudioMixer.shared.reconnect(); refresh() }
                Button(AppLanguage.text("Reconectar Spotify")) { SpotifyService.refresh(state); refresh() }
            }
            Button(AppLanguage.text("Exportar diagnóstico…")) {
                let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "notchJP-diagnostic.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try AppDiagnostics.encoded(AppDiagnostics.report(home: state.home)).write(to: url, options: .atomic); message = AppLanguage.text("Relatório salvo.") }
                catch { message = AppLanguage.text("Não foi possível salvar o relatório.") }
            }
            if let message { Text(message).font(.caption) }
        }.padding(28).onAppear { refresh() }
    }
    private func refresh() { report = AppDiagnostics.report(home: state.home) }
}
