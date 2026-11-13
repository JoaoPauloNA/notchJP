import SwiftUI

struct ResidentialTVControlView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject var controller: LGTVController
    @State private var volume = 0.0
    @State private var editing = false
    private let accent = NJP.accent
    private var disabled: Bool { !controller.connected || controller.busy || controller.waking }

    var body: some View {
        VStack(spacing: 12) {
            let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: composition.isExternal ? 12 : 28))
            layout {
                television.frame(maxWidth: .infinity).externalPanelCard()
                if !composition.isExternal { separator }
                navigation.frame(maxWidth: .infinity).externalPanelCard()
                if !composition.isExternal { separator }
                audioAndInputs.frame(maxWidth: .infinity).externalPanelCard()
            }.frame(height: composition.isExternal ? nil : 232)
            HStack(spacing: 8) {
                if controller.busy || controller.waking { ProgressView().controlSize(.mini) }
                else {
                    Circle().fill(controller.connected ? NJP.good : .white.opacity(0.3)).frame(width: 6, height: 6)
                }
                Text(controller.waking ? controller.message : controller.error ?? controller.message)
                    .font(.system(size: 11)).foregroundStyle(controller.error == nil ? .white.opacity(0.55) : .orange)
                    .lineLimit(2).help(controller.error ?? controller.message)
                Spacer()
                Button { Task { await controller.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(controller.busy || controller.waking).help(AppLanguage.text("Atualizar TV")).accessibilityLabel(AppLanguage.text("Atualizar TV"))
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).frame(minHeight: 22)
        }
        .padding(.horizontal, composition.isExternal ? 16 : 30).padding(.top, 18).padding(.bottom, 16)
        .foregroundStyle(Color.primary).tint(accent).preferredColorScheme(.dark)
        .onChange(of: controller.volume) { _, value in if !editing { volume = Double(value ?? 0) } }
        .task {
            volume = Double(controller.volume ?? 0)
            if CommandLine.arguments.contains("--render-residential-preview") { return }
            if !controller.waking { await controller.refresh() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                if !editing && controller.connected && !controller.waking { await controller.refresh() }
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
    }

    private var television: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(controller.displayName, systemImage: "tv").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let device = controller.selectedDevice {
                    ResidentialRenameButton(name: controller.displayName, originalName: controller.originalName) {
                        controller.rename(to: $0)
                    }.id(device.id)
                }
                Spacer()
                if !controller.connected {
                    Button { Task { await controller.wake() } } label: {
                        Label(controller.waking ? "Ligando…" : AppLanguage.text("Ligar TV"), systemImage: "power")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(accent.opacity(0.16), in: Capsule())
                    }.buttonStyle(.plain).disabled(controller.busy || controller.waking)
                        .accessibilityLabel(AppLanguage.text("Ligar TV")).help(AppLanguage.text("Ligar a TV pela rede local"))
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.15)))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(controller.connected ? 0.22 : 0.04), .black.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(7)
                VStack(spacing: 10) {
                    Image(systemName: controller.connected ? "wifi" : "tv").font(.system(size: 25, weight: .light))
                    Text("LG webOS").font(.system(size: 21, weight: .light))
                }.foregroundStyle(Color.primary.opacity(controller.connected ? 0.85 : 0.3))
            }.frame(height: 142)
            HStack {
                Text(controller.model)
                Spacer()
                Text(controller.connected ? AppLanguage.text("Conectada") : AppLanguage.text("Sem conexão"))
            }.font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7))
        }
    }

    private var navigation: some View {
        VStack(spacing: 12) {
            Text(AppLanguage.text("Controle remoto")).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.7))
            VStack(spacing: 4) {
                remoteButton("chevron.up", title: "Cima", command: "UP")
                HStack(spacing: 4) {
                    remoteButton("chevron.left", title: "Esquerda", command: "LEFT")
                    Button { controller.button("ENTER") } label: {
                        Text("OK").font(.system(size: 15, weight: .semibold))
                            .frame(width: 52, height: 52).background(accent.opacity(0.8), in: Circle())
                            .foregroundStyle(Color.primary)
                    }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(AppLanguage.text("Confirmar na TV"))
                    remoteButton("chevron.right", title: "Direita", command: "RIGHT")
                }
                remoteButton("chevron.down", title: "Baixo", command: "DOWN")
            }
            HStack(spacing: 32) {
                remoteButton("house", title: "Abrir launcher casa", command: "HOME")
                remoteButton("arrow.uturn.backward", title: AppLanguage.text("Voltar na TV"), command: "BACK")
            }
        }
    }

    private func remoteButton(_ symbol: String, title: String, command: String) -> some View {
        Button { controller.button(command) } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 33)
                .background(NJP.surface, in: Capsule())
        }.buttonStyle(.plain).disabled(disabled).help(title).accessibilityLabel(title)
    }

    private var audioAndInputs: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Volume").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.7))
                Spacer()
                Text(controller.connected ? "\(Int(editing ? volume : Double(controller.volume ?? 0)))" : "—")
                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
            }.frame(height: 48)
            HStack(spacing: 10) {
                Button { controller.changeVolume(-1) } label: { Image(systemName: "speaker.wave.1") }
                    .accessibilityLabel(AppLanguage.text("Diminuir volume"))
                Slider(value: $volume, in: 0...100, step: 1) { active in
                    editing = active
                    if !active { controller.setVolume(Int(volume.rounded())) }
                }.accessibilityLabel(AppLanguage.text("Volume da TV"))
                Button { controller.changeVolume(1) } label: { Image(systemName: "speaker.wave.3") }
                    .accessibilityLabel(AppLanguage.text("Aumentar volume"))
            }.buttonStyle(.plain).disabled(disabled)
            Button { controller.toggleMute() } label: {
                Label(controller.muted ? AppLanguage.text("Ativar som") : AppLanguage.text("Silenciar"), systemImage: controller.muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(NJP.surface, in: Capsule())
            }.buttonStyle(.plain).disabled(disabled)
            if composition.isExternal {
                Text(AppLanguage.text("Entradas HDMI / AV")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                    ForEach(controller.inputs) { input in
                        Button(input.label) { controller.switchInput(input.id) }
                            .font(.system(size: 11, weight: .medium)).padding(8)
                            .frame(maxWidth: .infinity).background(NJP.surfaceStrong, in: Capsule())
                    }
                }.buttonStyle(.plain).disabled(disabled || controller.inputs.isEmpty)
            } else {
            Menu(AppLanguage.text("Entradas HDMI / AV")) {
                ForEach(controller.inputs) { input in
                    Button(input.label + (input.connected ? " · conectado" : "")) { controller.switchInput(input.id) }
                }
            }.disabled(disabled || controller.inputs.isEmpty)            }

        }
    }
}

struct ResidentialTVSettingsView: View {
    @ObservedObject var controller: LGTVController
    @State private var address = ""
    @State private var mac = ""
    @State private var settingsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(controller.displayName, systemImage: "tv").font(.title2.weight(.semibold))
                if let device = controller.selectedDevice {
                    ResidentialRenameButton(name: controller.displayName, originalName: controller.originalName) {
                        controller.rename(to: $0)
                    }.id(device.id)
                }
            }
            Text(AppLanguage.text("Conecte a TV e o Mac à mesma rede. Na primeira conexão, aceite o pedido na tela da TV."))
                .font(.callout).foregroundStyle(.secondary)
            Button(controller.busy ? "Buscando…" : AppLanguage.text("Buscar TV na rede")) {
                Task { await controller.refresh(search: true) }
            }.disabled(controller.busy || controller.waking)
            ForEach(controller.foundDevices) { device in
                Button("\(controller.displayName(for: device)) · \(device.host)") {
                    Task { await controller.selectDevice(device) }
                }.disabled(controller.busy || controller.waking)
            }
            TextField(AppLanguage.text("Endereço IP da TV"), text: $address).textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppLanguage.text("Endereço IP da TV"))
            TextField(AppLanguage.text("Endereço MAC da TV (opcional)"), text: $mac).textFieldStyle(.roundedBorder)
            if !mac.isEmpty {
                Button(AppLanguage.text("Salvar endereço para ligar TV")) {
                    do { try controller.saveWakeMAC(mac); settingsError = nil }
                    catch { settingsError = error.localizedDescription }
                }
            }
            Text(AppLanguage.text("Para ligar pelo app, ative ‘Ligar via Wi-Fi’ em ‘TV ligada com dispositivo móvel’ na TV. O endereço MAC é salvo automaticamente após a conexão."))
                .font(.caption).foregroundStyle(.secondary)
            if let settingsError { Text(settingsError).font(.caption).foregroundStyle(.orange) }
            if controller.busy || controller.waking { ProgressView().controlSize(.small) }
            Text(controller.error ?? controller.message)
                .font(.caption).foregroundStyle(controller.error == nil ? Color.secondary : .orange)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button(AppLanguage.text("Conectar")) {
                    controller.host = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await controller.refresh() }
                }.buttonStyle(.borderedProminent).disabled(controller.busy || controller.waking || address.isEmpty)
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { address = controller.host; mac = controller.wakeMAC }
    }
}
