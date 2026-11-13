import SwiftUI

/// "Mac" page: disk, memory, CPU, battery, network and Bluetooth as rounded cards.
struct MacHealthView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject private var health = SystemHealthService.shared

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: composition.isVertical ? 2 : 3)
        VStack(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                diskCard
                memoryCard
                cpuCard
                batteryCard
                networkCard
                bluetoothCard
            }
            privacyStrip
        }
        .padding(.top, 2)
        .foregroundStyle(Color.primary)
        .onAppear { health.startLive() }
        .onDisappear { health.stopLive() }
    }

    private func tone(_ fraction: Double, warn: Double, bad: Double) -> Color {
        fraction >= bad ? NJP.bad : (fraction >= warn ? NJP.warn : NJP.good)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824).replacingOccurrences(of: ".", with: ",")
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "—" }
        let units: [(String, Double)] = [("MB/s", 1_000_000), ("KB/s", 1_000)]
        for (name, size) in units where value >= size {
            return String(format: "%.1f %@", value / size, name).replacingOccurrences(of: ".", with: ",")
        }
        return "\(Int(value)) B/s"
    }

    private func card(title: String, symbol: String, ring: Double, color: Color, label: String,
                      detail: String, extra: String? = nil) -> some View {
        HStack(spacing: 10) {
            NJPRing(progress: ring, color: color, label: label, lineWidth: 6).frame(width: 54, height: 54)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(2)
                if let extra {
                    Text(extra).font(.system(size: 9, weight: .semibold)).foregroundStyle(color).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .njpCard()
    }

    private func openStorage() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
    }

    private var diskCard: some View {
        if let disk = health.disk {
            let low = SystemHealthService.lowDiskGB(disk) != nil
            return AnyView(Button(action: openStorage) { card(
                title: "Disco", symbol: "internaldrive", ring: disk.usedFraction,
                color: low ? NJP.bad : tone(disk.usedFraction, warn: 0.8, bad: 0.92),
                label: "\(Int((disk.usedFraction * 100).rounded()))%",
                detail: "\(disk.availableGB) GB livres de \(disk.totalGB) GB",
                extra: low ? "Pouco espaço · toque" : "Toque para gerenciar") }
                .buttonStyle(.plain).help("Abrir o armazenamento do Mac"))
        }
        return AnyView(card(title: "Disco", symbol: "internaldrive", ring: 0, color: NJP.good, label: "—", detail: "Lendo…"))
    }

    private var memoryCard: some View {
        let fraction = health.memoryTotal > 0 ? Double(health.memoryUsed) / Double(health.memoryTotal) : 0
        return card(title: "Memória", symbol: "memorychip", ring: fraction,
                    color: tone(fraction, warn: 0.75, bad: 0.9),
                    label: health.memoryUsed == 0 ? "—" : "\(Int((fraction * 100).rounded()))%",
                    detail: "\(gb(health.memoryUsed)) de \(gb(health.memoryTotal)) GB")
    }

    private var cpuCard: some View {
        let usage = health.cpu
        return card(title: "Processador", symbol: "cpu", ring: usage ?? 0,
                    color: tone(usage ?? 0, warn: 0.6, bad: 0.85),
                    label: usage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    detail: usage == nil ? "Medindo…" : "Uso dos núcleos",
                    extra: health.topProcess.map { "Mais ativo: \($0.name)" })
    }

    private var batteryCard: some View {
        if let battery = health.battery {
            let level = Double(battery.percent) / 100
            let color: Color = battery.charging ? NJP.good : (battery.percent <= 15 ? NJP.bad : (battery.percent <= 30 ? NJP.warn : NJP.good))
            return AnyView(card(
                title: "Bateria", symbol: battery.charging ? "battery.100.bolt" : "battery.75",
                ring: level, color: color, label: "\(battery.percent)%",
                detail: battery.charging ? "Carregando" : (battery.onACPower ? "Na tomada" : "Na bateria")))
        }
        return AnyView(card(title: "Energia", symbol: "powerplug", ring: 1, color: NJP.good, label: "AC",
                            detail: "Este Mac não tem bateria"))
    }

    private var networkCard: some View {
        let busy = min(1, ((health.networkDown ?? 0) + (health.networkUp ?? 0)) / 12_500_000)
        return card(title: "Rede", symbol: "arrow.up.arrow.down", ring: busy, color: NJP.accent,
                    label: health.networkDown == nil ? "—" : "↓",
                    detail: "↓ \(Self.speed(health.networkDown))",
                    extra: "↑ \(Self.speed(health.networkUp))")
    }

    private var bluetoothCard: some View {
        let device = health.bluetooth.first { $0.percent != nil } ?? health.bluetooth.first
        guard let device else {
            return card(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", ring: 0, color: NJP.good, label: "—",
                        detail: "Nenhum acessório conectado")
        }
        let level = device.percent ?? 0
        let color: Color = level <= 15 ? NJP.bad : (level <= 30 ? NJP.warn : NJP.good)
        let others = health.bluetooth.count - 1
        return card(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right",
                    ring: Double(level) / 100, color: color,
                    label: device.percent.map { "\($0)%" } ?? "·",
                    detail: device.name, extra: others > 0 ? "+\(others) conectado\(others > 1 ? "s" : "")" : nil)
    }

    private var privacyStrip: some View {
        HStack(spacing: 10) {
            indicator("Microfone", symbol: "mic.fill", active: health.micInUse)
            indicator("Câmera", symbol: "video.fill", active: health.cameraInUse)
            Spacer(minLength: 0)
        }
    }

    private func indicator(_ title: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(active ? NJP.bad : NJP.good).frame(width: 7, height: 7)
            Image(systemName: symbol).font(.system(size: 11))
            Text("\(title): \(active ? "em uso" : "livre")").font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(active ? NJP.bad.opacity(0.18) : NJP.surface, in: Capsule())
    }
}
