import SwiftUI

struct HomeFavoritesView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject var home: HomeAutomation
    @Binding var selection: ResidentialDevice
    @State private var scheduling = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aparelhos favoritos").font(.headline)
                Spacer()
                Button("Temporizador", systemImage: "timer") { scheduling = true }
            }
            HomeDevicesList(home: home, selection: $selection)
            if !home.timers.isEmpty {
                Divider()
                ForEach(home.timers.reversed().prefix(20)) { timer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(timer.deviceName + (timer.action == .tvOff ? " · desligar TV" : " · \(timer.temperature) °C"))
                            Text(timer.status == .pending ? "Às \(timer.deadline.formatted(date: .omitted, time: .shortened))" : (timer.detail ?? timer.status.label))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if timer.status == .pending { Button("Cancelar") { home.cancel(timer.id) } }
                    }
                }
            }
            Text("Temporizadores funcionam com o Mac acordado e o notchJP aberto. Prazos perdidos são marcados como não executados.")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 12)).buttonStyle(HomeButtonStyle()).padding(24)
        .sheet(isPresented: $scheduling) { HomeTimerEditor(home: home) }
        .onChange(of: scheduling) { _, value in home.editorOpen = value }
        .onDisappear { home.editorOpen = false }
    }
}

private struct HomeDevicesList: View {
    @ObservedObject var home: HomeAutomation
    @ObservedObject private var air: ACController
    @ObservedObject private var tv: LGTVController
    @Binding var selection: ResidentialDevice
    init(home: HomeAutomation, selection: Binding<ResidentialDevice>) {
        self.home = home; air = home.air; tv = home.tv; _selection = selection
    }
    var body: some View {
        VStack(spacing: 8) {
            if air.devices.isEmpty && tv.selectedDevice == nil { Text("Conecte os aparelhos nos ajustes para escolher seus favoritos.").foregroundStyle(.secondary) }
            ForEach(air.devices.sorted { a, b in
                let af = home.favorites.contains("air:" + a.id), bf = home.favorites.contains("air:" + b.id)
                return af != bf ? af : a.name < b.name
            }) { device in
                row(id: "air:" + device.id, name: air.displayName(for: device), symbol: "air.conditioner.horizontal") {
                    air.select(device.id); selection = .air
                }
            }
            if let device = tv.selectedDevice {
                row(id: "tv:" + device.id, name: tv.displayName, symbol: "tv") { selection = .tv }
            }
        }.task { await air.refreshDevices() }
    }
    private func summary(_ id: String) -> String {
        if id.hasPrefix("tv:") { return tv.connected ? "Volume \(tv.volume ?? 0) · conectada" : "Sem conexão" }
        let key = String(id.dropFirst(4))
        guard let device = air.device(key), device.online else { return "Offline" }
        guard let value = air.states[key] ?? (air.selectedDeviceID == key ? air.state : nil) else { return "Aguardando estado" }
        return value.power ? "\(Int(value.temperature))° · \(value.mode.label)" : "Desligado"
    }
    private func row(id: String, name: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(NJP.accent)
                    VStack(alignment: .leading, spacing: 3) { Text(name); Text(summary(id)).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button { home.toggleFavorite(id) } label: {
                Image(systemName: home.favorites.contains(id) ? "star.fill" : "star")
            }.buttonStyle(.plain).help(home.favorites.contains(id) ? "Remover dos favoritos" : "Adicionar aos favoritos")
        }.padding(10).background(NJP.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct HomeScenesView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject var home: HomeAutomation
    @State private var editing: HomeScene?
    @State private var targets = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cenas da casa").font(.headline)
                Spacer()
                Button("Criar cena", systemImage: "plus") { editing = HomeScene() }
            }
            Text("Cenas prontas · selecione os ares abaixo").font(.caption).foregroundStyle(.secondary)
            ForEach(home.air.devices) { device in
                Toggle(home.air.displayName(for: device), isOn: Binding(get: { targets.contains(device.id) }, set: {
                    if $0 { targets.insert(device.id) } else { targets.remove(device.id) }
                }))
            }
            if composition.isExternal {
                ForEach([(id: "cinema", title: "Cinema", subtitle: "TV na HDMI e ar em 22°", icon: "film"),
                         (id: "night", title: "Boa noite", subtitle: "TV desligada e ar em 24°, sem desligar o ar", icon: "moon.stars"),
                         (id: "off", title: "Desligar TV", subtitle: "Mantém o ar como está", icon: "tv.slash")], id: \.id) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).foregroundStyle(NJP.accent)
                        VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.headline); Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Rodar") { runPreset(item.id) }.disabled(home.running)
                    }.externalPanelCard()
                }
                Text("Minhas cenas").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Cinema") { runPreset("cinema") }
                    Button("Boa noite") { runPreset("night") }
                    Button("Desligar TV") { runPreset("off") }
                }.disabled(home.running)
            }
            ForEach(home.scenes) { scene in
                let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())
                layout {
                    Button(scene.name) { Task { await home.run(scene) } }.disabled(home.running)
                    if let raw = scene.shortcut, let key = GlobalShortcut(rawValue: raw) { Text(key.displayName).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Editar") { editing = scene }
                    Button("Excluir", role: .destructive) { home.delete(scene.id) }
                }.padding(10).background(NJP.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if composition.isExternal { Text("Nenhuma cena desliga o ar.").font(.caption).foregroundStyle(.secondary) }
            if home.running { ProgressView("Executando…") }
            if let message = home.message { Text(message).foregroundStyle(NJP.warn).font(.caption) }
            ForEach(home.results) { result in
                Label(result.name + ": " + (result.error ?? "Comandos aceitos"), systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(result.succeeded ? NJP.good : NJP.warn).font(.caption)
            }
        }.font(.system(size: 12)).buttonStyle(HomeButtonStyle()).padding(24)
        .task { await home.air.refreshDevices() }
        .sheet(item: $editing) { scene in HomeSceneEditor(home: home, scene: scene) }
        .onChange(of: editing != nil) { _, value in home.editorOpen = value }
        .onDisappear { home.editorOpen = false }
    }
    private func runPreset(_ id: String) {
        var scene = HomeScene()
        scene.name = id == "cinema" ? "Cinema" : id == "night" ? "Boa noite" : "Desligar TV"
        scene.airIDs = id == "off" ? [] : Array(targets)
        scene.temperature = id == "cinema" ? 22 : 24
        scene.turnAirOn = id == "cinema"; scene.sleep = id == "night"; scene.eco = id == "night"
        scene.tvID = home.tv.selectedDevice?.id
        scene.tvAction = id == "cinema" ? .input : .off
        scene.input = home.tv.inputs.first(where: { $0.id.hasPrefix("HDMI") })?.id
        Task { await home.run(scene) }
    }
}

struct HomeSceneEditor: View {
    @ObservedObject var home: HomeAutomation
    @State var scene: HomeScene
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Editar cena").font(.title2)
            Form {
                TextField("Nome", text: $scene.name)
                Section("Ar-condicionado") {
                    ForEach(home.air.devices) { device in
                        Toggle(home.air.displayName(for: device), isOn: Binding(get: { scene.airIDs.contains(device.id) }, set: { on in
                            scene.airIDs.removeAll { $0 == device.id }; if on { scene.airIDs.append(device.id) }
                        }))
                    }
                    if !scene.airIDs.isEmpty {
                        Stepper("Temperatura: \(scene.temperature) °C", value: $scene.temperature, in: 16...32)
                        Picker("Modo", selection: $scene.mode) { ForEach(ACMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                        Picker("Ventilação", selection: $scene.fan) { ForEach(ACFan.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                        Toggle("Ligar os ares escolhidos", isOn: $scene.turnAirOn)
                        Toggle("Modo dormir", isOn: $scene.sleep)
                        Toggle("Economia de energia", isOn: $scene.eco)
                    }
                }
                Section("TV") {
                    Picker("Ação", selection: $scene.tvAction) {
                        Text("Não alterar").tag(HomeTVAction.none); Text("Ligar").tag(HomeTVAction.on)
                        Text("Desligar").tag(HomeTVAction.off); Text("Escolher entrada").tag(HomeTVAction.input)
                    }
                    if scene.tvAction != .none { Text(home.tv.displayName) }
                    if scene.tvAction == .input {
                        Picker("Entrada", selection: Binding(get: { scene.input ?? "" }, set: { scene.input = $0 })) {
                            Text("Selecione").tag("")
                            ForEach(home.tv.inputs) { Text($0.label).tag($0.id) }
                        }
                        Text("Conecte a TV no painel para carregar suas entradas.").font(.caption)
                    }
                }
                Picker("Atalho global", selection: Binding(get: { scene.shortcut ?? "" }, set: { scene.shortcut = $0.isEmpty ? nil : $0 })) {
                    Text("Sem atalho").tag("")
                    ForEach(1...9, id: \.self) { slot in
                        if let key = HomeSceneShortcuts.shortcut(slot: slot) { Text(key.displayName).tag(key.rawValue) }
                    }
                }
                Text("Os atalhos funcionam enquanto o notchJP está aberto.").font(.caption)
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Salvar") {
                    scene.tvID = scene.tvAction == .none ? nil : home.tv.selectedDevice?.id
                    error = home.save(scene)
                    if error == nil { dismiss() }
                }.buttonStyle(.borderedProminent)
            }
        }.buttonStyle(HomeButtonStyle()).padding(22).frame(width: 500, height: 600)
    }
}

private struct HomeTimerEditor: View {
    @ObservedObject var home: HomeAutomation
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var minutes = 30
    @State private var temperature = 24
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Temporizador de aparelho").font(.title2)
            Picker("Aparelho", selection: $target) {
                Text("Selecione").tag("")
                ForEach(home.air.devices) { Text(home.air.displayName(for: $0)).tag("air:" + $0.id) }
                if let tv = home.tv.selectedDevice { Text(home.tv.displayName).tag("tv:" + tv.id) }
            }
            Stepper("Daqui a \(minutes) minutos", value: $minutes, in: 1...1440)
            if target.hasPrefix("air:") { Stepper("Ajustar para \(temperature) °C", value: $temperature, in: 16...32) }
            else if target.hasPrefix("tv:") { Text("Desligar a TV") }
            Text("Mantenha o Mac acordado e o notchJP aberto até a execução.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancelar") { dismiss() }; Spacer()
                Button("Agendar") {
                    let isAir = target.hasPrefix("air:")
                    let id = String(target.dropFirst(3 + (isAir ? 1 : 0)))
                    let name = isAir ? (home.air.device(id).map { home.air.displayName(for: $0) } ?? "Ar") : home.tv.displayName
                    error = home.schedule(HomeTimer(deviceID: id, deviceName: name, deadline: Date().addingTimeInterval(Double(minutes) * 60), action: isAir ? .airTemperature : .tvOff, temperature: temperature))
                    if error == nil { dismiss() }
                }.disabled(target.isEmpty).buttonStyle(.borderedProminent)
            }
        }.buttonStyle(HomeButtonStyle()).padding(24).frame(width: 430)
    }
}

extension HomeTimer.Status {
    var label: String {
        switch self { case .pending: "Agendado"; case .running: "Executando"; case .succeeded: "Concluído"; case .failed: "Falhou"; case .missed: "Não executado"; case .cancelled: "Cancelado" }
    }
}

private struct HomeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? NJP.warn : .white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(NJP.surfaceStrong.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.45)
    }
}
