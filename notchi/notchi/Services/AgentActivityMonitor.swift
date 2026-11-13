import Combine
import Foundation

struct AgentSessionSnapshot: Equatable, Identifiable {
    enum Phase: Equatable { case working, needsApproval, done }

    let id: String
    let agent: String
    let project: String
    var cwd: String = ""
    var processId: Int? = nil
    var phase: Phase
    var since: Date
    /// True when the session just finished a run, so "pronto" is worth announcing.
    var finishedWork: Bool
}

/// Listens to the hook socket and keeps one snapshot per Claude Code / Codex / Devin session.
/// It only observes: it never answers a permission request, so the terminal prompt keeps working.
@MainActor
final class AgentActivityMonitor: ObservableObject {
    static let shared = AgentActivityMonitor()

    /// How long a finished run is announced beside the notch.
    static let doneWindow: TimeInterval = 25

    @Published private(set) var sessions: [AgentSessionSnapshot] = []
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        SocketServer.shared.start { envelope in
            let provider = envelope.provider.displayName
            let session = envelope.sessionId
            let project = URL(fileURLWithPath: envelope.cwd).lastPathComponent
            let event = envelope.event
            let cwd = envelope.cwd
            let pid = envelope.claudeProcessId ?? envelope.codexProcessId ?? envelope.devinProcessId ?? envelope.agyProcessId
            Task { @MainActor in
                AgentActivityMonitor.shared.handle(sessionId: session, agent: provider, project: project, event: event,
                                                   cwd: cwd, processId: pid)
            }
            return nil
        }
    }

    func stop() {
        guard started else { return }
        started = false
        SocketServer.shared.stop()
        sessions = []
    }

    func handle(sessionId: String, agent: String, project: String, event rawEvent: String,
                cwd: String = "", processId: Int? = nil, now: Date = Date()) {
        guard let event = NormalizedAgentEvent(rawValue: rawEvent) else { return }
        var list = sessions.filter { now.timeIntervalSince($0.since) < 6 * 3600 }
        let index = list.firstIndex { $0.id == sessionId }
        let previous = index.map { list[$0] }

        guard let phase = Self.phase(for: event) else {
            if event == .sessionEnded, let index { list.remove(at: index) }
            sessions = list
            return
        }
        let finishedWork = phase == .done && previous?.phase == .working
        let next = AgentSessionSnapshot(
            id: sessionId, agent: agent, project: project.isEmpty ? agent : project,
            cwd: cwd.isEmpty ? (previous?.cwd ?? "") : cwd, processId: processId ?? previous?.processId,
            phase: phase,
            since: previous?.phase == phase ? previous!.since : now,
            finishedWork: finishedWork || (phase == .done && previous?.finishedWork == true && previous?.phase == .done))
        if let index { list[index] = next } else { list.append(next) }
        sessions = list

        if finishedWork {
            // Make observers re-evaluate once the announcement window has passed.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.doneWindow + 1))
                self.sessions = self.sessions
            }
        }
    }

    static func phase(for event: NormalizedAgentEvent) -> AgentSessionSnapshot.Phase? {
        switch event {
        case .permissionRequest: .needsApproval
        case .stop: .done
        case .sessionStarted: .done
        case .userPromptSubmitted, .preToolUse, .postToolUse, .preCompact: .working
        case .subagentStop, .sessionEnded: nil
        }
    }

    /// What the notch should announce, or nil. Approval beats a finished run.
    func alert(now: Date = Date()) -> NotchAlert? {
        Self.alert(from: sessions, now: now)
    }

    static func alert(from sessions: [AgentSessionSnapshot], now: Date) -> NotchAlert? {
        if let waiting = sessions.filter({ $0.phase == .needsApproval }).min(by: { $0.since < $1.since }) {
            return .agentApproval(project: waiting.project, agent: waiting.agent)
        }
        if let done = sessions
            .filter({ $0.phase == .done && $0.finishedWork && now.timeIntervalSince($0.since) < doneWindow })
            .max(by: { $0.since < $1.since }) {
            return .agentDone(project: done.project)
        }
        return nil
    }
}
