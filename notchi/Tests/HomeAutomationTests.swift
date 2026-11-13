import XCTest
import SwiftUI
@testable import notchi

@MainActor final class HomeAutomationTests: XCTestCase {
    private final class Backend: ACBackend {
        // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
        nonisolated deinit {}
        let name = "fake"
        var sent: [String] = []
        var failID: String?
        func configure(email: String, password: String, region: String) async throws {}
        func listDevices() async throws -> [ACDeviceInfo] {
            [ACDeviceInfo(id: "a", name: "Sala", online: true), ACDeviceInfo(id: "b", name: "Quarto", online: true)]
        }
        func readState() async throws -> ACState {
            ACState(power: true, temperature: 24, roomTemperature: 26, eco: false, mode: .cool, fan: .auto, sleep: false, airflow: .off)
        }
        func perform(_ command: ACCommand) async throws -> ACState { XCTFail("Comando sem destinatário"); return try await readState() }
        func perform(_ command: ACCommand, deviceID: String) async throws -> ACState {
            sent.append(deviceID)
            if failID == deviceID { throw TCLBackendError("Sem resposta") }
            if case .power(false) = command { XCTFail("Cena desligou o ar") }
            return try await readState()
        }
    }
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!
    override func setUp() async throws {
        suite = "home-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func make(_ backend: Backend? = nil) -> HomeAutomation {
        HomeAutomation(air: ACController(backend: backend ?? Backend(), deviceNames: ResidentialDeviceNames(defaults: defaults)),
                       tv: LGTVController(store: LGTVPairingStore(directory: directory), deviceNames: ResidentialDeviceNames(defaults: defaults)), defaults: defaults)
    }
    func testScenesAndFavoritesSurviveReopeningAndCanBeDeleted() {
        let home = make()
        var scene = HomeScene(); scene.name = "Trabalhar"; scene.airIDs = ["a"]
        XCTAssertNil(home.save(scene)); home.toggleFavorite("air:a")
        let reopened = make()
        XCTAssertEqual(reopened.scenes, [scene]); XCTAssertTrue(reopened.favorites.contains("air:a"))
        reopened.delete(scene.id)
        XCTAssertTrue(make().scenes.isEmpty)
    }
    func testPartialFailureIsReportedPerDeviceAndStopsFailedDevicesCommands() async {
        let backend = Backend(); backend.failID = "a"
        let home = make(backend)
        var scene = HomeScene(); scene.airIDs = ["a", "b"]
        await home.run(scene)
        XCTAssertEqual(home.results.count, 2)
        XCTAssertEqual(home.results.first?.error, "Sem resposta")
        XCTAssertTrue(home.results.last?.succeeded == true)
        XCTAssertEqual(backend.sent.filter { $0 == "a" }.count, 1)
        XCTAssertEqual(backend.sent.filter { $0 == "b" }.count, 5)
    }
    func testMissingTargetDoesNotFallBackToAnotherAirConditioner() async {
        let backend = Backend(); let home = make(backend)
        var scene = HomeScene(); scene.airIDs = ["removed"]
        await home.run(scene)
        XCTAssertTrue(backend.sent.isEmpty)
        XCTAssertFalse(home.results[0].succeeded)
    }
    func testDuplicateShortcutsAreRejectedWithoutOverwritingScenes() {
        let home = make()
        var a = HomeScene(); a.airIDs = ["a"]; a.shortcut = HomeSceneShortcuts.shortcut(slot: 1)?.rawValue
        XCTAssertNil(home.save(a))
        var b = a; b.id = UUID().uuidString
        XCTAssertNotNil(home.save(b)); XCTAssertEqual(home.scenes.count, 1)
    }
    func testTimersAreCancelledOrMissedWithoutSendingCommands() async {
        let backend = Backend(); let home = make(backend); let now = Date()
        let cancelled = HomeTimer(deviceID: "a", deviceName: "Sala", deadline: now.addingTimeInterval(30), action: .airTemperature)
        XCTAssertNil(home.schedule(cancelled, now: now)); home.cancel(cancelled.id)
        let expired = HomeTimer(deviceID: "b", deviceName: "Quarto", deadline: now.addingTimeInterval(40), action: .airTemperature)
        XCTAssertNil(home.schedule(expired, now: now))
        await home.tick(now: now.addingTimeInterval(180))
        XCTAssertEqual(home.timers.map(\.status), [.cancelled, .missed]); XCTAssertTrue(backend.sent.isEmpty)
    }
    func testTimerTargetsOnlyItsSavedDeviceAndRunsOnce() async {
        let backend = Backend(); let home = make(backend); let now = Date()
        XCTAssertNil(home.schedule(HomeTimer(deviceID: "b", deviceName: "Quarto", deadline: now.addingTimeInterval(10), action: .airTemperature), now: now))
        await home.tick(now: now.addingTimeInterval(11)); await home.tick(now: now.addingTimeInterval(12))
        XCTAssertEqual(backend.sent, ["b"]); XCTAssertEqual(home.timers.first?.status, .succeeded)
    }
    func testFailedSceneDoesNotStartFocus() async {
        let backend = Backend(); backend.failID = "a"
        let home = make(backend); var scene = HomeScene(); scene.airIDs = ["a"]
        XCTAssertNil(home.save(scene)); FocusTimerService.shared.reset()
        await home.startFocus(minutes: 25, sceneID: scene.id)
        XCTAssertEqual(FocusTimerService.shared.state, .idle)
        XCTAssertNotNil(home.message)
    }
    func testQuickReminderParsingAndLimits() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(QuickReminder.parse("Beber água em 20 minutos", now: now), QuickReminder(title: "Beber água", due: now.addingTimeInterval(1200)))
        XCTAssertEqual(QuickReminder.parse("me avisar em 1 hora", now: now)?.title, "Lembrete")
        XCTAssertNil(QuickReminder.parse("em 20 minutos"))
        XCTAssertNil(QuickReminder.parse("Reunião em 0 min"))
        XCTAssertNil(QuickReminder.parse("Reunião em 9999 horas"))
    }
    func testSpotifyDiagnosticsDistinguishPermissionAndTimeout() {
        XCTAssertTrue(SpotifyService.diagnostic(code: -1743).contains("Automação"))
        XCTAssertTrue(SpotifyService.diagnostic(code: -1712).contains("não respondeu"))
    }
    func testReopeningMarksOverdueTimersWithoutExecutingThem() {
        let home = make(); let now = Date()
        XCTAssertNil(home.schedule(HomeTimer(deviceID: "a", deviceName: "Sala", deadline: now.addingTimeInterval(10), action: .airTemperature), now: now))
        let reopened = make()
        reopened.recoverTimers(now: now.addingTimeInterval(20))
        XCTAssertEqual(reopened.timers.first?.status, .missed)
        XCTAssertEqual(make().timers.first?.status, .missed)
    }

    func testRenderHomeFormsWithIsolatedDevices() async throws {
        let home = make()
        await home.air.refreshDevices()
        var scene = HomeScene(); scene.name = "Trabalhar"; scene.airIDs = ["a", "b"]
        XCTAssertNil(home.save(scene)); home.toggleFavorite("air:a")
        try await render(HomeSceneEditor(home: home, scene: scene), size: CGSize(width: 500, height: 600), name: "editor")
        try await render(HomeScenesView(home: home), size: CGSize(width: 960, height: 320), name: "scenes")
        try await render(HomeFavoritesView(home: home, selection: .constant(.favorites)), size: CGSize(width: 960, height: 320), name: "favorites")
    }
    private func render<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(Color.black))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/notchjp-source-\(name).png"))
        window.contentView = nil
    }

}
