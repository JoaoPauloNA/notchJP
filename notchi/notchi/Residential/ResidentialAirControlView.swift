import SwiftUI

enum ResidentialDevice: String, CaseIterable {
    case favorites, air, tv, scenes
    var title: String {
        switch self {
        case .favorites: AppLanguage.text("Favoritos")
        case .air: "Ar"
        case .tv: "TV"
        case .scenes: AppLanguage.text("Cenas")
        }
    }
    var symbol: String {
        switch self {
        case .favorites: "star"
        case .air: "air.conditioner.horizontal"
        case .tv: "tv"
        case .scenes: "sparkles"
        }
    }
}

enum NotchDashboardMode {
    case overview, residential

    mutating func toggleResidential() {
        self = self == .residential ? .overview : .residential
    }
}

struct ResidentialAirControlView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject var controller: ACController
    @Binding var directionAxis: WindDirectionIcon.Axis?
    @State private var target = 24.0
    @State private var editingTemperature = false
    private let accent = NJP.accent
    private var state: ACState? { controller.state }
    private var unavailable: Bool { state == nil || controller.busy }
    /// Several air conditioners on the account: a switcher takes the top row.
    private var multi: Bool { controller.devices.count > 1 }

    var body: some View {
        VStack(spacing: multi ? 10 : 12) {
            if multi { deviceSwitcher }
            let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: composition.isExternal ? 12 : 28))
            layout {
                appliance.frame(maxWidth: .infinity).externalPanelCard()
                if !composition.isExternal { separator }
                temperatureAndMode.frame(maxWidth: .infinity).externalPanelCard()
                if !composition.isExternal { separator }
                comfort.frame(maxWidth: .infinity).externalPanelCard()
            }
            .frame(height: composition.isExternal ? nil : (multi ? 206 : 232))
            footer
        }
        .padding(.horizontal, composition.isExternal ? 16 : 30)
        .padding(.top, multi ? 10 : 18)
        .padding(.bottom, multi ? 12 : 16)
        .foregroundStyle(Color.primary)
        .tint(accent)
        .preferredColorScheme(.dark)
        .onChange(of: state?.temperature) { _, value in
            if !editingTemperature, let value { target = value }
        }
        .task {
            target = state?.temperature ?? 24
            await controller.refresh()
            await controller.refreshOthers()
            var round = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                round += 1
                if !editingTemperature { await controller.refresh() }
                // The other air conditioners only need a look once a minute.
                if round % 3 == 0, multi { await controller.refreshOthers() }
            }
        }
    }

    /// One chip per air conditioner, with its temperature, so the others can be seen without switching.
    private var deviceSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.devices) { device in chip(device) }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 34)
    }

    private func chip(_ device: ACDeviceInfo) -> some View {
        let selected = device.id == controller.selectedDeviceID
        let known = selected ? controller.state : controller.states[device.id]
        let dot: Color = !device.online ? .white.opacity(0.3) : ((known?.power ?? false) ? NJP.good : .white.opacity(0.55))
        return Button { controller.select(device.id) } label: {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(controller.displayName(for: device)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !device.online {
                    Text("offline").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                } else if let known {
                    Text(known.power ? "\(Int(known.temperature))°" : "desl.")
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Color.primary.opacity(selected ? 0.85 : 0.6))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(selected ? accent : NJP.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Controlar \(controller.displayName(for: device))")
        .accessibilityLabel(controller.displayName(for: device))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
    }

    private var appliance: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "air.conditioner.horizontal")
                    .foregroundStyle(accent)
                Text(controller.selectedDisplayName)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if controller.selectedDeviceID != nil {
                    ResidentialRenameButton(name: controller.selectedDisplayName, originalName: controller.originalSelectedName) {
                        controller.renameSelected(to: $0)
                    }.id(controller.selectedDeviceID)
                }
                Spacer(minLength: 0)
                Button { controller.send(.power(!(state?.power ?? false))) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(state?.power == true ? accent : .white.opacity(0.6))
                        .background(NJP.surfaceStrong, in: Circle())
                }
                .buttonStyle(.plain).disabled(unavailable)
                .help(state?.power == true ? "Desligar ar-condicionado" : "Ligar ar-condicionado")
                .accessibilityLabel(AppLanguage.text("Ligar ou desligar o ar"))
            }
            AirConditionerVisual(running: state?.power == true,
                                 temperature: state?.temperature, airflow: state?.airflow ?? .off)
                .frame(height: composition.isVertical ? 220 : (composition.isExternal ? 170 : (multi ? 124 : 150)))
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                Text(state?.roomTemperature.map { "Ambiente  \(Int($0))°C" } ?? "Ambiente  —")
                Spacer()
                Text(state.map { $0.power ? AppLanguage.text("Ligado") : AppLanguage.text("Desligado") } ?? "TCL Home")
            }
            .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7))
        }
    }

    private var temperatureAndMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLanguage.text("Temperatura")).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.7))
                Spacer()
                Text(state == nil ? "—" : "\(Int(editingTemperature ? target : (state?.temperature ?? target)))°")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }.frame(height: 48)
            HStack(spacing: 12) {
                temperatureButton("minus", delta: -1)
                Slider(value: $target, in: 16...32, step: 1) { editing in
                    editingTemperature = editing
                    if !editing { controller.send(.temperature(target)) }
                }
                .disabled(unavailable)
                .accessibilityLabel("Temperatura do ar-condicionado")
                temperatureButton("plus", delta: 1)
            }
            HStack {
                Text("16°C")
                Spacer()
                Text("32°C")
            }.font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
            if composition.isExternal {
                Text(AppLanguage.text("Modo")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 6) {
                    ForEach(ACMode.allCases, id: \.self) { mode in
                        Button { controller.send(.mode(mode)) } label: {
                            Text(mode.label).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(state?.mode == mode ? accent : NJP.surfaceStrong, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.disabled(unavailable)
                Picker(AppLanguage.text("Ventilação"), selection: Binding(get: { state?.fan ?? .auto }, set: { controller.send(.fan($0)) })) {
                    ForEach(ACFan.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).disabled(unavailable)
            } else {
            Picker(AppLanguage.text("Modo"), selection: Binding(get: { state?.mode ?? .cool }, set: { controller.send(.mode($0)) })) {
                ForEach(ACMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(unavailable)
            Picker(AppLanguage.text("Ventilação"), selection: Binding(get: { state?.fan ?? .auto }, set: { controller.send(.fan($0)) })) {
                ForEach(ACFan.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(unavailable)            }

        }
        .font(.system(size: 12))
    }

    private var comfort: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(AppLanguage.text("Direção do vento")).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
            HStack(spacing: 12) {
                directionMenu(vertical: true)
                directionMenu(vertical: false)
            }
            HStack {
                Toggle("Eco", isOn: Binding(get: { state?.eco ?? false }, set: { controller.send(.eco($0)) }))
                Spacer(minLength: 14)
                Toggle(AppLanguage.text("Dormir"), isOn: Binding(get: { state?.sleep ?? false }, set: { controller.send(.sleep($0)) }))
            }
            .toggleStyle(.switch).controlSize(.small).disabled(unavailable)
            Toggle(AppLanguage.text("Brisa suave"), isOn: Binding(get: { state?.breeze ?? false }, set: { controller.send(.breeze($0)) }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(unavailable || state?.breeze == nil || (state?.mode != .cool && state?.breeze != true))
                .help(state?.breeze == nil ? AppLanguage.text("Indisponível neste aparelho") : AppLanguage.text("Disponível no modo Resfriar"))
        }
        .font(.system(size: 12))
    }

    private func directionMenu(vertical: Bool) -> some View {
        let axis: WindDirectionIcon.Axis = vertical ? .vertical : .horizontal
        return Button { directionAxis = axis } label: {
            VStack(spacing: 4) {
                WindDirectionIcon(axis: vertical ? .vertical : .horizontal,
                                  direction: (vertical ? state?.verticalDirection?.rawValue : state?.horizontalDirection?.rawValue) ?? 0)
                    .frame(width: 54, height: 54)
                Text(vertical ? "Vertical" : "Horizontal").font(.system(size: 11, weight: .medium))
                Text((vertical ? state?.verticalDirection?.label : state?.horizontalDirection?.label) ?? AppLanguage.text("Indisponível"))
                    .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(NJP.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { directionAxis == axis }, set: { if !$0 { directionAxis = nil } }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                if vertical {
                    ForEach(ACVerticalDirection.choices, id: \.self) { direction in
                        Button {
                            controller.send(.verticalDirection(direction))
                            directionAxis = nil
                        } label: {
                            directionLabel(direction.label, selected: state?.verticalDirection == direction)
                        }
                    }
                } else {
                    ForEach(ACHorizontalDirection.choices, id: \.self) { direction in
                        Button {
                            controller.send(.horizontalDirection(direction))
                            directionAxis = nil
                        } label: {
                            directionLabel(direction.label, selected: state?.horizontalDirection == direction)
                        }
                    }
                }
            }
            .buttonStyle(.plain).padding(12).frame(width: 215).preferredColorScheme(.dark)
        }
        .disabled(unavailable || (vertical ? state?.verticalDirection == nil : state?.horizontalDirection == nil))
        .accessibilityLabel(vertical ? AppLanguage.text("Direção vertical") : AppLanguage.text("Direção horizontal"))
    }

    private func directionLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(accent) }
        }
        .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity).contentShape(Rectangle())
    }

    private func temperatureButton(_ symbol: String, delta: Double) -> some View {
        Button {
            guard let state else { return }
            target = min(32, max(16, state.temperature + delta))
            controller.send(.temperature(target))
        } label: {
            Image(systemName: symbol).frame(width: composition.isExternal ? 44 : 32, height: composition.isExternal ? 44 : 32)
                .background(NJP.surfaceStrong, in: Circle())
        }
        .buttonStyle(.plain).disabled(unavailable)
        .accessibilityLabel(delta > 0 ? AppLanguage.text("Aumentar temperatura") : AppLanguage.text("Diminuir temperatura"))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if controller.busy { ProgressView().controlSize(.mini) }
            else {
                Circle().fill(controller.error == nil && state != nil ? NJP.good : .white.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
            Text(controller.busy ? "Atualizando…" : controller.error ?? (state == nil ? AppLanguage.text("Conecte sua conta TCL Home para controlar o ar.") : AppLanguage.text("Conectado à TCL Home")))
                .font(.system(size: 11)).foregroundStyle(controller.error == nil ? .white.opacity(0.55) : .orange)
                .lineLimit(2).help(controller.error ?? "")
            Spacer(minLength: 12)
            Button { Task { await controller.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }.disabled(controller.busy).help(AppLanguage.text("Atualizar estado")).accessibilityLabel(AppLanguage.text("Atualizar estado"))
        }
        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
        .frame(minHeight: 22)
    }
}
