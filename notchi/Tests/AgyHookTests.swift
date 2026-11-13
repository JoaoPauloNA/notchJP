import XCTest
@testable import notchi

final class AgyHookTests: XCTestCase {
    /// The user's real file at the time: another tool (ai-memory) already owns entries.
    private let existing = """
    {
      "ai-memory": {
        "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "/x/ai-memory hook --event pre-tool-use"}]}],
        "PreInvocation": [{"type": "command", "command": "/x/ai-memory hook --event session-start"}],
        "Stop": [{"type": "command", "command": "/x/ai-memory hook --event stop"}]
      }
    }
    """

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testUpsertAddsOnlyTheNotchjpEntryAndKeepsOthersUntouched() throws {
        let original = try object(Data(existing.utf8))
        let updated = try object(try XCTUnwrap(AgyHookInstaller.upsert(from: Data(existing.utf8), script: "/h/notchjp-agy-hook.sh")))
        XCTAssertEqual(Set(updated.keys), ["ai-memory", "notchjp"])
        XCTAssertTrue(NSDictionary(dictionary: original["ai-memory"] as! [String: Any]).isEqual(to: updated["ai-memory"] as! [String: Any]))
        let mine = try XCTUnwrap(updated["notchjp"] as? [String: Any])
        XCTAssertEqual(Set(mine.keys), ["PreInvocation", "PreToolUse", "PostToolUse", "Stop"])
        let pre = try XCTUnwrap((mine["PreToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(pre["matcher"] as? String, "")
        let command = try XCTUnwrap(((pre["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        XCTAssertEqual(command, "\"/h/notchjp-agy-hook.sh\" PreToolUse")
        let stop = try XCTUnwrap((mine["Stop"] as? [[String: Any]])?.first)
        XCTAssertEqual(stop["command"] as? String, "\"/h/notchjp-agy-hook.sh\" Stop")
    }

    func testUpsertTwiceChangesNothing() throws {
        let once = try XCTUnwrap(AgyHookInstaller.upsert(from: Data(existing.utf8), script: "/h/s.sh"))
        let twice = try XCTUnwrap(AgyHookInstaller.upsert(from: once, script: "/h/s.sh"))
        XCTAssertEqual(once, twice)
    }

    func testRemoveGivesBackTheOriginalEntries() throws {
        let installed = try XCTUnwrap(AgyHookInstaller.upsert(from: Data(existing.utf8), script: "/h/s.sh"))
        XCTAssertTrue(AgyHookInstaller.hasEntry(in: installed))
        let removed = try object(try XCTUnwrap(AgyHookInstaller.remove(from: installed)))
        XCTAssertFalse(removed.keys.contains("notchjp"))
        XCTAssertTrue(NSDictionary(dictionary: try object(Data(existing.utf8))).isEqual(to: removed))
    }

    func testAnInvalidFileIsNeverOverwritten() {
        XCTAssertNil(AgyHookInstaller.upsert(from: Data("não é json".utf8), script: "/h/s.sh"))
        XCTAssertNil(AgyHookInstaller.remove(from: Data("[1,2]".utf8)))
        XCTAssertNotNil(AgyHookInstaller.upsert(from: nil, script: "/h/s.sh"), "arquivo inexistente é criado")
        XCTAssertNotNil(AgyHookInstaller.upsert(from: Data(), script: "/h/s.sh"), "arquivo vazio é preenchido")
    }

    func testAGYIsAKnownProvider() {
        XCTAssertEqual(AgentProvider.agy.displayName, "AGY")
        XCTAssertEqual(AgentProvider(rawValue: "agy"), .agy)
    }

    /// Runs the real script against a real socket server and checks the app understands what arrives.
    func testHookScriptSendsAnEnvelopeAndNeverTheStdinPayload() throws {
        let home = "/tmp/njp-\(UUID().uuidString.prefix(8))"
        let socketPath = SocketServer.resolvedSocketPath(home: home)
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let script = try XCTUnwrap(Bundle.main.url(forResource: "notchi-agy-hook", withExtension: "sh"))

        let received = LockedBox<[AgentHookEnvelope]>([])
        let arrived = expectation(description: "evento recebido")
        arrived.assertForOverFulfill = false
        let server = SocketServer(socketPath: socketPath, clientReadTimeout: 1)
        server.start { envelope in
            received.mutate { $0.append(envelope) }
            arrived.fulfill()
            return nil
        }
        defer { server.stop() }
        // The server starts asynchronously; wait for the socket file.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socketPath) { Thread.sleep(forTimeInterval: 0.1) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "PreInvocation"]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"prompt":"SEGREDO-NAO-DEVE-SAIR"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        wait(for: [arrived], timeout: 8)

        let envelope = try XCTUnwrap(received.value.first)
        XCTAssertEqual(envelope.provider, .agy)
        XCTAssertEqual(envelope.event, "UserPromptSubmit")
        XCTAssertEqual(envelope.status, "processing")
        XCTAssertTrue(envelope.sessionId.hasPrefix("agy-"))
        XCTAssertNil(envelope.userPrompt, "o texto do usuário nunca é enviado")
        XCTAssertNotNil(NormalizedAgentEvent(rawValue: envelope.event))
    }

    @MainActor
    func testTheMonitorShowsAGYAsWorkingThenDone() {
        let monitor = AgentActivityMonitor.shared
        let now = Date()
        monitor.handle(sessionId: "agy-1", agent: "AGY", project: "notchJP", event: "UserPromptSubmit", now: now)
        XCTAssertEqual(monitor.sessions.first { $0.id == "agy-1" }?.phase, .working)
        monitor.handle(sessionId: "agy-1", agent: "AGY", project: "notchJP", event: "Stop", now: now.addingTimeInterval(5))
        XCTAssertEqual(monitor.alert(now: now.addingTimeInterval(6)), .agentDone(project: "notchJP"))
        monitor.handle(sessionId: "agy-1", agent: "AGY", project: "notchJP", event: "SessionEnd", now: now)
    }
}

nonisolated private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
