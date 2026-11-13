import SwiftUI

/// Composition changes with the display; controls continue using the same controllers.
nonisolated enum PanelComposition: Equatable {
    case notch, side, top
    var isExternal: Bool { self != .notch }
    var isVertical: Bool { self == .side }
}
private struct PanelCompositionKey: EnvironmentKey {
    static let defaultValue = PanelComposition.notch
}
extension EnvironmentValues {
    var panelComposition: PanelComposition {
        get { self[PanelCompositionKey.self] }
        set { self[PanelCompositionKey.self] = newValue }
    }
}

struct ExternalPanelCard: ViewModifier {
    @Environment(\.panelComposition) private var composition
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("njp.liquidGlass") private var glass = false
    func body(content: Content) -> some View {
        if composition.isExternal {
            content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(glass && !reduceTransparency ? Color.white.opacity(0.055) : NJP.layer2,
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(glass && !reduceTransparency ? 0.12 : 0.09)) }
        } else { content }
    }
}
extension View {
    func externalPanelCard() -> some View { modifier(ExternalPanelCard()) }
}

struct DockRailButton: View {
    let symbol: String
    let title: String
    var selected = false
    var badge = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? Color.white : .white.opacity(hovering ? 1 : 0.4))
                .frame(width: 40, height: 40)
                .background(selected ? NJP.accent : (hovering ? NJP.layer3 : .clear), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(.orange).frame(width: 8, height: 8).overlay(Circle().stroke(NJP.layer1, lineWidth: 2)).offset(x: -2, y: 2) }
                }
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onHover { hovering = $0 }
    }
}

struct DockStatusTab: View {
    let alert: NotchAlert?
    let anchor: DashboardAnchor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: alert?.ticksEverySecond == true ? 1 : 15)) { context in
            ZStack(alignment: anchor == .left ? .trailing : .leading) {
                VStack(spacing: 7) {
                    if case .nowPlaying = alert {
                        TimelineView(.animation(minimumInterval: 0.15, paused: reduceMotion)) { tick in
                            HStack(alignment: .center, spacing: 2) {
                                ForEach(0..<3) { index in
                                    Capsule().fill(NJP.accent).frame(width: 3, height: reduceMotion ? 12 : 6 + 12 * abs(sin(tick.date.timeIntervalSinceReferenceDate * 3 + Double(index))))
                                }
                            }.frame(height: 20)
                        }
                    } else {
                        Image(systemName: alert?.symbol ?? "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                            .symbolEffect(.pulse, isActive: !reduceMotion && alert?.pulses == true)
                    }
                    if let label = label(now: context.date) {
                        Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.64)).lineLimit(1).minimumScaleFactor(0.65)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 22)
            }
        }.accessibilityLabel(alert?.accessibilityText ?? "Abrir notchJP")
    }
    private var tint: Color {
        switch alert {
        case .agentApproval, .lowDisk: .orange
        case .privacy, .dictation: .red
        case .event: .blue
        case .none, .agentDone, .timerDone: .green
        default: NJP.accent
        }
    }
    private func label(now: Date) -> String? {
        switch alert {
        case .none, .nowPlaying, .dictation: nil
        case .event(_, let date): "\(max(0, Int(ceil(date.timeIntervalSince(now) / 60))))m"
        case .agentApproval: "1"
        case .agentDone: "ok"
        default: alert?.label(now: now)
        }
    }
}

@MainActor enum DisplayPanelPreferences {
    static func key(for screen: NSScreen) -> String {
        let id = ScreenIdentifier(screen: screen)
        return "njp.panel.sideStyle." + (id.displayID.map(String.init) ?? id.localizedName)
    }
    static func usesDrawer(on screen: NSScreen) -> Bool { UserDefaults.standard.string(forKey: key(for: screen)) != "strip" }
}
