import SwiftUI

/// One-tap combinations of TV and air-conditioner settings.
struct ResidentialScene: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    /// Runs on the TV once and on every chosen air conditioner (`targets` is empty for a single-appliance backend).
    let run: @MainActor (ACController, LGTVController, [String]) async -> Void

    @MainActor static let all: [ResidentialScene] = [
        ResidentialScene(id: "cinema", title: "Cinema", subtitle: "TV na HDMI e ar em 22°", symbol: "film") { air, tv, targets in
            await air.sendAndWait(.power(true), toEach: targets)
            await air.sendAndWait(.mode(.cool), toEach: targets)
            await air.sendAndWait(.temperature(22), toEach: targets)
            await air.sendAndWait(.fan(.auto), toEach: targets)
            if !tv.connected { await tv.wake() }
            await tv.refresh()
            if let hdmi = tv.inputs.first(where: { $0.label.localizedCaseInsensitiveContains("hdmi") && $0.connected })
                ?? tv.inputs.first(where: { $0.label.localizedCaseInsensitiveContains("hdmi") }) {
                if let id = tv.selectedDevice?.id { _ = await tv.performSceneAction(.input, input: hdmi.id, expectedID: id) }
            }
        },
        ResidentialScene(id: "night", title: "Boa noite", subtitle: "TV desligada e ar em 24° no modo dormir (continua ligado)", symbol: "moon.stars") { air, tv, targets in
            if let id = tv.selectedDevice?.id { _ = await tv.performSceneAction(.off, input: nil, expectedID: id) }
            // Keeps the air on: only the setpoint and sleep mode change.
            await air.sendAndWait(.mode(.cool), toEach: targets)
            await air.sendAndWait(.temperature(24), toEach: targets)
            await air.sendAndWait(.sleep(true), toEach: targets)
            await air.sendAndWait(.eco(true), toEach: targets)
        },
        // The air conditioner is never switched off by a scene (see Controles/ArVPS/README.md).
        ResidentialScene(id: "off", title: "Desligar a TV", subtitle: "Só a TV; o ar continua como está", symbol: "tv.slash") { _, tv, _ in
            if let id = tv.selectedDevice?.id { _ = await tv.performSceneAction(.off, input: nil, expectedID: id) }
        },
    ]
}

extension ACController {
    /// Sends the command to each id in turn; with no ids it goes to the selected (or only) device.
    func sendAndWait(_ command: ACCommand, toEach ids: [String]) async {
        if ids.isEmpty { await sendAndWait(command); return }
        for id in ids { await sendAndWait(command, to: id) }
    }
}
