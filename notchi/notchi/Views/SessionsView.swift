import SwiftUI

/// "Agentes" page: every Claude Code / Codex session seen by the hooks, tap to jump to its terminal.
struct SessionsView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject private var monitor = AgentActivityMonitor.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if monitor.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(sorted) { session in row(session) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.top, 2)
    }

    private var sorted: [AgentSessionSnapshot] {
        monitor.sessions.sorted {
            if ($0.phase == .needsApproval) != ($1.phase == .needsApproval) { return $0.phase == .needsApproval }
            return $0.since > $1.since
        }
    }

    private func row(_ session: AgentSessionSnapshot) -> some View {
        Button {
            if !TerminalFocus.activate(processId: session.processId), !session.cwd.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
            }
        } label: {
            let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 9)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Circle().fill(color(session.phase).opacity(0.25)).frame(width: 38, height: 38)
                    .overlay { Image(systemName: symbol(session.phase)).font(.system(size: 15, weight: .semibold)).foregroundStyle(color(session.phase)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(session.agent).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(label(session.phase)).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(color(session.phase).opacity(0.18), in: Capsule())
                        .foregroundStyle(color(session.phase))
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.elapsed(since: session.since, now: context.date))
                            .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .padding(.bottom, composition.isExternal && session.phase == .needsApproval ? 18 : 0)
            .frame(maxWidth: .infinity)
            .njpCard(radius: composition.isExternal ? 14 : 20)
            .overlay { if composition.isExternal && session.phase == .needsApproval { RoundedRectangle(cornerRadius: 14).stroke(NJP.warn, lineWidth: 1) } }
            .overlay(alignment: .bottomTrailing) {
                if composition.isExternal && session.phase == .needsApproval { Text("Abrir terminal para responder").font(.system(size: 10)).foregroundStyle(NJP.warn).padding(8) }
            }
        }
        .buttonStyle(.plain)
        .help("Ir para o terminal desta sessão")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(Color.primary.opacity(0.7))
            Text("Nenhuma sessão ativa").font(.system(size: 15, weight: .bold))
            Text("Abra o Claude Code ou o Codex. Sem hooks instalados, as sessões não aparecem.")
                .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7)).multilineTextAlignment(.center)
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Abrir ajustes de Agentes").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7).background(NJP.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func elapsed(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "agora" }
        if seconds < 3600 { return "há \(seconds / 60) min" }
        return "há \(seconds / 3600) h"
    }

    private func label(_ phase: AgentSessionSnapshot.Phase) -> String {
        switch phase {
        case .working: "Trabalhando"
        case .needsApproval: "Precisa de você"
        case .done: "Pronto"
        }
    }

    private func color(_ phase: AgentSessionSnapshot.Phase) -> Color {
        switch phase {
        case .working: NJP.accent
        case .needsApproval: NJP.warn
        case .done: NJP.good
        }
    }

    private func symbol(_ phase: AgentSessionSnapshot.Phase) -> String {
        switch phase {
        case .working: "bolt.fill"
        case .needsApproval: "hand.raised.fill"
        case .done: "checkmark"
        }
    }
}
