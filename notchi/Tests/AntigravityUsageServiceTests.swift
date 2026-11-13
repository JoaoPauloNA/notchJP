import XCTest
@testable import notchi

@MainActor
final class AntigravityUsageServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func payload(argon: Any = 0.85, gemini: Any = 0.99,
                         reset: String = "2030-01-01T00:00:00Z",
                         status: String = "SUCCESS", command: String = "usage",
                         duplicate: Bool = false, argonWindow: String = "weekly") throws -> Data {
        let argonBucket: [String: Any] = ["id": "gemini-argon-wtu-weekly", "window": argonWindow,
                                         "remaining_fraction": argon, "reset_time": reset]
        return try JSONSerialization.data(withJSONObject: [
            "status": status, "command": ["name": command, "data": ["groups": [
                ["name": "Gemini Models", "buckets": [
                    ["id": "gemini-5h", "window": "5h", "remaining_fraction": gemini, "reset_time": reset],
                    ["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.97, "reset_time": reset]
                ]],
                ["name": "Gemini 4 Argon", "buckets": duplicate ? [argonBucket, argonBucket] : [argonBucket]],
                ["name": "Claude and GPT models", "buckets": [
                    ["id": "3p-weekly", "window": "weekly", "remaining_fraction": 0.2, "reset_time": reset]
                ]]
            ]]]
        ])
    }

    func testKeepsArgonWeeklySeparateFromSharedGeminiWindows() throws {
        let result = try AntigravityUsageSnapshot.parse(payload(), now: now)
        XCTAssertEqual(result.argonWeekly?.usagePercentage, 15)
        XCTAssertEqual(result.geminiSession?.usagePercentage, 1)
        XCTAssertEqual(result.geminiWeekly?.usagePercentage, 3)
    }

    func testRejectsInvalidFractionsAndBooleans() throws {
        for value: Any in [true, -0.1, 1.1, "0.85"] {
            XCTAssertThrowsError(try AntigravityUsageSnapshot.parse(payload(argon: value), now: now))
        }
    }

    func testRejectsWrongCommandFailureAndDuplicateBuckets() throws {
        XCTAssertThrowsError(try AntigravityUsageSnapshot.parse(payload(status: "FAILED"), now: now))
        XCTAssertThrowsError(try AntigravityUsageSnapshot.parse(payload(command: "model"), now: now))
        XCTAssertThrowsError(try AntigravityUsageSnapshot.parse(payload(duplicate: true), now: now))
        XCTAssertThrowsError(try AntigravityUsageSnapshot.parse(payload(argonWindow: "5h"), now: now))
    }

    func testDoesNotInventQuotasAfterReset() throws {
        let result = try AntigravityUsageSnapshot.parse(payload(reset: "2020-01-01T00:00:00Z"), now: now)
        XCTAssertNil(result.argonWeekly)
        XCTAssertNil(result.geminiSession)
        XCTAssertNil(result.geminiWeekly)
        XCTAssertThrowsError(try AntigravityUsageSnapshot.parse(payload(reset: "invalid"), now: now))
    }

    func testRefreshPublishesBothModels() async throws {
        let data = try payload()
        let service = AntigravityUsageService(fetch: { data }, now: { self.now })
        await service.refresh()
        XCTAssertEqual(service.snapshot.argonWeekly?.usagePercentage, 15)
        XCTAssertEqual(service.snapshot.geminiSession?.usagePercentage, 1)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertFalse(service.isRefreshing)
    }

    func testFailedRefreshKeepsLastGoodQuotasMarkedStale() async throws {
        let responses = ResponseQueue(data: try payload())
        let service = AntigravityUsageService(fetch: { try await responses.next() }, now: { self.now })
        await service.refresh()
        await service.refresh()
        XCTAssertEqual(service.snapshot.argonWeekly?.usagePercentage, 15)
        XCTAssertTrue(service.isUsageStale)
        XCTAssertFalse(service.isRefreshing)
    }

    func testFailureDiscardsExpiredQuotas() async throws {
        let responses = ResponseQueue(data: try payload())
        var date = now
        let service = AntigravityUsageService(fetch: { try await responses.next() }, now: { date })
        await service.refresh()
        date = Date(timeIntervalSince1970: 2_000_000_000)
        await service.refresh()
        XCTAssertNil(service.snapshot.argonWeekly)
        XCTAssertNil(service.snapshot.geminiSession)
        XCTAssertNil(service.snapshot.geminiWeekly)
        XCTAssertFalse(service.isUsageStale)
    }

    func testCommandUsesOnlyUsageWithBoundedPrintMode() async throws {
        let script = try executable("""
        #!/bin/sh
        [ "$#" -eq 8 ] || exit 64
        printf '["%s","%s","%s","%s","%s","%s","%s","%s"]\\n' "$@"
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let data = try await Task.detached { try AntigravityUsageCommand.capture(executable: script) }.value
        let arguments = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(arguments, ["--log-file", "/dev/null", "--print", "/usage", "--output-format", "json", "--print-timeout", "20s"])
    }

    func testCommandTerminatesStalledProcess() async throws {
        let script = try executable("#!/bin/sh\nexec /bin/sleep 10\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        do {
            _ = try await Task.detached { try AntigravityUsageCommand.capture(executable: script, timeout: 0.1) }.value
            XCTFail("Expected bounded command timeout")
        } catch {
            XCTAssertEqual(error as? AntigravityUsageError, .timedOut)
        }
    }

    private func executable(_ content: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-agy")
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private actor ResponseQueue {
        var data: Data?
        init(data: Data) { self.data = data }
        func next() throws -> Data {
            guard let result = data else { throw AntigravityUsageError.commandFailed }
            data = nil
            return result
        }
    }
}
