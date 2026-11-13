import XCTest
@testable import notchi

@MainActor
final class AgentActivityMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var monitor: AgentActivityMonitor { .shared }

    override func tearDown() async throws {
        for session in monitor.sessions {
            monitor.handle(sessionId: session.id, agent: session.agent, project: session.project, event: "SessionEnd", now: now)
        }
    }

    func testPermissionRequestAnnouncesApprovalUntilTheToolRuns() {
        monitor.handle(sessionId: "s1", agent: "Claude Code", project: "notchJP", event: "UserPromptSubmit", now: now)
        monitor.handle(sessionId: "s1", agent: "Claude Code", project: "notchJP", event: "PermissionRequest", now: now)
        XCTAssertEqual(monitor.alert(now: now), .agentApproval(project: "notchJP", agent: "Claude Code"))

        monitor.handle(sessionId: "s1", agent: "Claude Code", project: "notchJP", event: "PostToolUse", now: now)
        XCTAssertNil(monitor.alert(now: now))
    }

    func testFinishingARunAnnouncesDoneOnlyForAShortWindow() {
        monitor.handle(sessionId: "s2", agent: "Codex", project: "api", event: "UserPromptSubmit", now: now)
        monitor.handle(sessionId: "s2", agent: "Codex", project: "api", event: "Stop", now: now)
        XCTAssertEqual(monitor.alert(now: now.addingTimeInterval(5)), .agentDone(project: "api"))
        XCTAssertNil(monitor.alert(now: now.addingTimeInterval(AgentActivityMonitor.doneWindow + 1)))
    }

    func testStartingASessionDoesNotAnnounceDone() {
        monitor.handle(sessionId: "s3", agent: "Claude Code", project: "x", event: "SessionStart", now: now)
        XCTAssertNil(monitor.alert(now: now))
    }

    func testSessionEndRemovesTheSessionAndUnknownEventsAreIgnored() {
        monitor.handle(sessionId: "s4", agent: "Claude Code", project: "x", event: "UserPromptSubmit", now: now)
        monitor.handle(sessionId: "s4", agent: "Claude Code", project: "x", event: "Qualquer", now: now)
        XCTAssertEqual(monitor.sessions.filter { $0.id == "s4" }.count, 1)
        monitor.handle(sessionId: "s4", agent: "Claude Code", project: "x", event: "SessionEnd", now: now)
        XCTAssertTrue(monitor.sessions.filter { $0.id == "s4" }.isEmpty)
    }

    func testApprovalWinsOverFinishedRuns() {
        monitor.handle(sessionId: "a", agent: "Codex", project: "done", event: "UserPromptSubmit", now: now)
        monitor.handle(sessionId: "a", agent: "Codex", project: "done", event: "Stop", now: now)
        monitor.handle(sessionId: "b", agent: "Claude Code", project: "waiting", event: "PermissionRequest", now: now)
        XCTAssertEqual(monitor.alert(now: now), .agentApproval(project: "waiting", agent: "Claude Code"))
    }
}

final class NJPSettingsAndHealthTests: XCTestCase {
    func testTopProcessSkipsTheAppAndPs() {
        let output = """
         42,5 notchi
         31,0 Google Chrome
          2,1 ps
        """
        let top = SystemHealthService.parseTopProcess(output, ignoring: ["ps", "notchi"])
        XCTAssertEqual(top?.name, "Google Chrome")
        XCTAssertEqual(top?.cpu ?? 0, 31.0, accuracy: 0.01)
    }

    func testAccentIndexFallsBackToTheFirstColour() {
        UserDefaults.standard.set(99, forKey: NJPSettings.accentIndexKey)
        XCTAssertEqual(NJPSettings.accentIndex, 0)
        UserDefaults.standard.removeObject(forKey: NJPSettings.accentIndexKey)
    }

    func testHoverDelayDefaultsToThreeHundredMilliseconds() {
        UserDefaults.standard.removeObject(forKey: NJPSettings.hoverDelayKey)
        XCTAssertEqual(NJPSettings.hoverDelay, 0.3, accuracy: 0.001)
    }
}
