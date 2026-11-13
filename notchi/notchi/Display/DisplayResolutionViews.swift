import SwiftUI

extension Notification.Name {
    static let openDisplayResolutionSettings = Notification.Name("njp.openDisplayResolutionSettings")
}

struct DisplayResolutionQuickMenu: View {
    @ObservedObject private var service = DisplayResolutionService.shared
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Menu {
            if service.screens.isEmpty { Text("Nenhuma tela disponível") }
            ForEach(service.screens) { screen in
                Menu(screen.name) {
                    if let current = screen.current { Text("Atual: \(current.title)") }
                    Divider()
                    let selected = service.selectedModes(screen)
                    if selected.isEmpty { Text("Escolha favoritas em Ajustes → Telas") }
                    ForEach(selected) { mode in
                        Button { service.apply(mode, screen: screen.id) } label: {
                            if mode == screen.current { Label(mode.title, systemImage: "checkmark") }
                            else { Text(mode.title) }
                        }
                        .disabled(service.pendingScreen != nil || screen.mirrored || mode == screen.current)
                    }
                    if screen.mirrored { Text("Tela espelhada: ajuste pelo macOS") }
                }
            }
            if service.pendingScreen != nil {
                Divider()
                Button("Manter resolução") { service.keep() }
                Button("Restaurar anterior") { service.revert() }
            }
            if let error = service.error { Divider(); Text(error) }
            Divider()
            Button("Configurar resoluções…") {
                openSettings()
                NSApp.activate()
                NotificationCenter.default.post(name: .openDisplayResolutionSettings, object: nil)
                // Settings may be created on the next event-loop iteration.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .openDisplayResolutionSettings, object: nil)
                }
            }
        } label: {
            Image(systemName: "display").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Mudar resolução da tela")
        .accessibilityLabel("Resoluções favoritas das telas")
        .accessibilityIdentifier("quick-display-resolution")
    }
}

struct DisplayResolutionSettingsView: View {
    @ObservedObject private var service = DisplayResolutionService.shared
    @State private var selection = ""
    private var screen: ResolutionScreen? { service.screens.first { $0.id == selection } ?? service.screens.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Telas e resoluções").font(.title2.weight(.semibold))
            Text("Marque as resoluções que quer no menu do monitor, no cabeçalho do notch. As favoritas são salvas separadamente para cada tela.")
                .foregroundStyle(.secondary)
            DisplayArrangementPreview()
            if !service.screens.isEmpty {
                Picker("Tela", selection: Binding(get: { screen?.id ?? "" }, set: { selection = $0 })) {
                    ForEach(service.screens) { screen in Text(screen.name).tag(screen.id) }
                }
            }
            if let screen {
                if let mode = screen.current { Text("Atual: \(mode.title)").font(.headline) }
                if screen.mirrored { Text("Esta tela está espelhada. Para alterar somente ela, desative o espelhamento nos Ajustes do macOS.").foregroundStyle(.secondary) }
                Text("Resoluções favoritas").font(.headline)
                ForEach(screen.modes) { mode in
                    Toggle(isOn: Binding(get: { service.isFavorite(mode, screen: screen.id) }, set: { service.setFavorite(mode, screen: screen.id, enabled: $0) })) {
                        HStack {
                            Text(mode.title)
                            Spacer()
                            if mode == screen.current { Text("Atual").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
                if screen.modes.isEmpty { Text("O macOS não informou modos disponíveis para esta tela.").foregroundStyle(.secondary) }
                Text("HiDPI mantém a nitidez Retina. As dimensões indicam o espaço de trabalho; a imagem pode usar mais pixels físicos. Após uma troca, confirme em até 15 segundos para manter a resolução.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nenhuma tela disponível.").foregroundStyle(.secondary)
            }
            if let error = service.error { Text(error).foregroundStyle(.red) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { service.refresh() }
    }
}

struct ResolutionConfirmationView: View {
    @ObservedObject var service: DisplayResolutionService
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manter esta resolução?").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil((service.deadline ?? context.date).timeIntervalSince(context.date))))
                Text("A anterior será restaurada em \(remaining) segundos.").font(.callout)
            }
            HStack {
                Button("Restaurar anterior") { service.revert() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Manter") { service.keep() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 390, height: 155)
    }
}

private struct DisplayArrangementPreview: View {
    @State private var screens = NSScreen.screens
    @State private var revision = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Painel por tela").font(.headline)
            ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                let anchor = DashboardAnchor.resolve(screen: screen.frame, primary: screens.first?.frame ?? screen.frame)
                HStack(spacing: 14) {
                    ZStack(alignment: anchor == .left ? .leading : (anchor == .right ? .trailing : .top)) {
                        RoundedRectangle(cornerRadius: 6).fill(NJP.layer2).frame(width: 88, height: 52)
                        RoundedRectangle(cornerRadius: 3).fill(NJP.accent)
                            .frame(width: anchor.isSide ? 5 : 26, height: anchor.isSide ? 25 : 5)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(screen.localizedName).font(.system(size: 12, weight: .semibold))
                        Text(index == 0 && screen.hasNotch ? "Notch da tela principal" : anchor == .left ? "Gaveta na borda esquerda" : anchor == .right ? "Gaveta na borda direita" : "Painel no topo")
                            .font(.caption).foregroundStyle(.secondary)
                        if anchor.isSide {
                            let _ = revision
                            Picker("Layout", selection: Binding(get: { DisplayPanelPreferences.usesDrawer(on: screen) ? "drawer" : "strip" }, set: { style in
                                UserDefaults.standard.set(style, forKey: DisplayPanelPreferences.key(for: screen))
                                revision += 1
                                NotificationCenter.default.post(name: .njpSettingsChanged, object: nil)
                            })) { Text("Gaveta").tag("drawer"); Text("Faixa").tag("strip") }.pickerStyle(.segmented)
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(NJP.surface, in: RoundedRectangle(cornerRadius: 14))
            }
        }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NSScreen.screens }
    }
}
