import SwiftUI
import XCTest
@testable import notchi

final class ToolsAndHealthTests: XCTestCase {
    // MARK: Cost summary
    private func report(_ costs: [Double]) -> DailyCostReport {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-86_400 * Double(costs.count - 1))
        var buckets: DayModelBuckets = [:]
        for (index, cost) in costs.enumerated() {
            let date = calendar.date(byAdding: .day, value: index, to: start)!
            var totals = ModelTokenTotals()
            totals.costNanos = Int(cost * 1_000_000_000)
            totals.requestCount = 1
            totals.pricedCount = 1
            buckets[DailyCostReport.dayKey(date, calendar: calendar)] = ["modelo": totals]
        }
        return DailyCostReport.make(provider: .claude, buckets: buckets, windowStart: start, today: Date(), calendar: calendar)
    }

    func testCostSummaryAddsProvidersDayByDay() {
        let summary = CostSummary.make([("Claude", report([1, 2, 3])), ("Codex", report([0.5, 0.5, 0.5])), ("Devin", nil)])
        XCTAssertEqual(summary.today, 3.5, accuracy: 0.001)
        XCTAssertEqual(summary.window, 7.5, accuracy: 0.001)
        XCTAssertEqual(summary.daily.count, 3)
        XCTAssertEqual(summary.byProvider.map(\.name), ["Claude", "Codex"])
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(CostSummary.make([("Claude", nil)]).isEmpty)
    }

    // MARK: Timer
    func testTimerFormatting() {
        XCTAssertEqual(FocusTimerService.format(1445), "24:05")
        XCTAssertEqual(FocusTimerService.format(3600), "1:00:00")
        XCTAssertEqual(FocusTimerService.format(0.2), "00:01")
        XCTAssertEqual(FocusTimerService.format(-5), "00:00")
    }

    @MainActor
    func testTimerRunsPausesAndResets() {
        let timer = FocusTimerService.shared
        let now = Date()
        timer.start(minutes: 25, now: now)
        XCTAssertEqual(timer.remaining(now: now.addingTimeInterval(60)), 24 * 60, accuracy: 0.5)
        XCTAssertEqual(timer.progress(now: now.addingTimeInterval(750)), 0.5, accuracy: 0.01)
        timer.pause(now: now.addingTimeInterval(300))
        XCTAssertEqual(timer.remaining(now: now.addingTimeInterval(9999)), 20 * 60, accuracy: 0.5)
        timer.resume(now: now.addingTimeInterval(400))
        XCTAssertEqual(timer.remaining(now: now.addingTimeInterval(460)), 19 * 60, accuracy: 0.5)
        timer.reset()
        XCTAssertEqual(timer.state, .idle)
    }

    // MARK: Shortcuts, shelf, clipboard
    func testMergingKeepsOrderDropsDuplicatesAndCaps() {
        XCTAssertEqual(ProjectShortcutsStore.merging(["/a", "/b", "/a", "/c"], into: ["/z"], limit: 3), ["/z", "/a", "/b"])
    }

    func testClipboardInsertDedupesTrimsAndSkipsBlank() {
        var list = ClipboardHistoryService.insert("um", into: [])
        list = ClipboardHistoryService.insert("dois", into: list)
        list = ClipboardHistoryService.insert("um", into: list)
        XCTAssertEqual(list, ["um", "dois"])
        XCTAssertEqual(ClipboardHistoryService.insert("   \n", into: list), list)
        XCTAssertEqual(ClipboardHistoryService.insert(String(repeating: "x", count: 900), into: []).first?.count, 400)
        XCTAssertEqual(ClipboardHistoryService.insert("c", into: (0..<12).map(String.init), limit: 12).count, 12)
    }

    func testClipboardIgnoresPasswordManagerPasteboards() {
        XCTAssertFalse(ClipboardHistoryService.shouldRecord(types: [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]))
        XCTAssertTrue(ClipboardHistoryService.shouldRecord(types: [.string]))
    }

    // MARK: Reminders
    func testRemindersOrderedByDueThenUndatedAndCappedAtEight() {
        let now = Date()
        let items = [
            ReminderItem(id: "3", title: "Sem data", due: nil, listName: "L"),
            ReminderItem(id: "2", title: "Tarde", due: now.addingTimeInterval(7200), listName: "L"),
            ReminderItem(id: "1", title: "Cedo", due: now, listName: "L"),
        ]
        XCTAssertEqual(RemindersService.ordered(items).map(\.id), ["1", "2", "3"])
        let many = (0..<12).map { ReminderItem(id: "\($0)", title: "t\($0)", due: nil, listName: "L") }
        XCTAssertEqual(RemindersService.ordered(many).count, 8)
    }

    // MARK: Network and Bluetooth
    func testNetworkRateHandlesCounterWrap() {
        let start = Date()
        let normal = SystemHealthService.networkRate(from: (1_000, 500, start), to: (3_000_000, 500_500, start.addingTimeInterval(2)))
        XCTAssertEqual(normal.down, 1_499_500, accuracy: 1)
        XCTAssertEqual(normal.up, 250_000, accuracy: 1)
        let wrapped = SystemHealthService.networkRate(from: (4_294_967_000, 0, start), to: (704, 0, start.addingTimeInterval(1)))
        XCTAssertEqual(wrapped.down, 1_000, accuracy: 1)
        XCTAssertEqual(SystemHealthService.networkRate(from: (1, 1, start), to: (2, 2, start)).down, 0)
    }

    func testSpeedFormatting() {
        XCTAssertEqual(MacHealthView.speed(nil), "—")
        XCTAssertEqual(MacHealthView.speed(512), "512 B/s")
        XCTAssertEqual(MacHealthView.speed(2_300), "2,3 KB/s")
        XCTAssertEqual(MacHealthView.speed(4_560_000), "4,6 MB/s")
    }

    func testBluetoothParsingReadsBatteryAndConnectedDevices() throws {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods de JP":{"device_batteryLevelLeft":"80%","device_batteryLevelRight":"72%","device_batteryLevelCase":"50%"}},
          {"Teclado":{"device_batteryLevelMain":"41%"}},
          {"Mouse":{"device_minorType":"Mouse"}}
        ]}]}
        """
        let devices = SystemHealthService.parseBluetooth(Data(json.utf8))
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices.first { $0.name == "AirPods de JP" }?.percent, 72)
        XCTAssertEqual(devices.first { $0.name == "Teclado" }?.percent, 41)
        XCTAssertNil(devices.first { $0.name == "Mouse" }?.percent)
        XCTAssertEqual(devices.last?.name, "Mouse")
        XCTAssertTrue(SystemHealthService.parseBluetooth(Data("lixo".utf8)).isEmpty)
    }

    // MARK: Terminal and sessions
    func testTTYNameIsNormalised() {
        XCTAssertEqual(TerminalFocus.normalizedTTY("ttys003\n"), "ttys003")
        XCTAssertNil(TerminalFocus.normalizedTTY("??"))
        XCTAssertNil(TerminalFocus.normalizedTTY("  "))
        XCTAssertNil(TerminalFocus.normalizedTTY("tty;rm"))
    }

    func testParentProcessOfAChildIsThisProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        XCTAssertEqual(TerminalFocus.parentPID(of: child.processIdentifier), getpid())
    }

    func testElapsedText() {
        let now = Date()
        XCTAssertEqual(SessionsView.elapsed(since: now.addingTimeInterval(-20), now: now), "agora")
        XCTAssertEqual(SessionsView.elapsed(since: now.addingTimeInterval(-300), now: now), "há 5 min")
        XCTAssertEqual(SessionsView.elapsed(since: now.addingTimeInterval(-7300), now: now), "há 2 h")
    }

    // MARK: Alerts
    func testNewAlertLabels() {
        let now = Date()
        XCTAssertEqual(NotchAlert.timer(end: now.addingTimeInterval(754)).label(now: now), "12:34")
        XCTAssertEqual(NotchAlert.timerDone.label(now: now), "fim")
        XCTAssertEqual(NotchAlert.nowPlaying(title: "Faixa").label(now: now), "Faixa")
        XCTAssertEqual(NotchAlert.privacy(mic: true, camera: false).label(now: now), "mic")
        XCTAssertEqual(NotchAlert.privacy(mic: false, camera: true).label(now: now), "câmera")
        XCTAssertEqual(NotchAlert.privacy(mic: true, camera: true).label(now: now), "mic+cam")
        XCTAssertTrue(NotchAlert.timer(end: now).ticksEverySecond)
        XCTAssertTrue(NotchAlert.nowPlaying(title: "x").animatesIcon)
    }

    func testRebuildScriptQuotesTheRepoAndSwapsTheApp() {
        let script = LocalBuilder.script(repo: "/Users/x/Meu Projeto")
        XCTAssertTrue(script.contains("cd '/Users/x/Meu Projeto'"))
        XCTAssertTrue(script.contains("build-local-app.sh"))
        XCTAssertTrue(script.contains("/Applications/notchJP.app"))
        XCTAssertNil(LocalBuilder.validRepo("/tmp/nao-existe-njp"))
    }
}

@MainActor
final class ResidentialScenesSafetyTests: XCTestCase {
    private final class RecordingBackend: ACBackend {
        let name = "teste"
        var commands: [ACCommand] = []
        var value = ACState(power: true, temperature: 26, roomTemperature: 30, eco: false, mode: .cool, fan: .auto,
                            sleep: false, airflow: .vertical)
        func configure(email: String, password: String, region: String) async throws {}
        func readState() async throws -> ACState { value }
        func perform(_ command: ACCommand) async throws -> ACState { commands.append(command); return value }
    }

    func testNoSceneEverSwitchesTheAirConditionerOff() async {
        let backend = RecordingBackend()
        let air = ACController(backend: backend, initialState: backend.value)
        let tv = LGTVController(store: LGTVPairingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), preview: true)
        for scene in ResidentialScene.all where scene.id != "cinema" {
            await scene.run(air, tv, [])
        }
        for command in backend.commands {
            if case .power(false) = command { XCTFail("uma cena desligou o ar") }
        }
        XCTAssertFalse(backend.commands.isEmpty, "Boa noite deveria ajustar o ar")
    }
}

final class AppControlTests: XCTestCase {
    func testRestartScriptWaitsForTheProcessAndQuotesThePath() {
        let script = AppControl.restartScript(bundlePath: "/Applications/Meu App's/notchi.app", pid: 123)
        XCTAssertTrue(script.contains("kill -0 123"))
        XCTAssertTrue(script.contains("/usr/bin/open '/Applications/Meu App'\\''s/notchi.app'"), script)
    }
}
