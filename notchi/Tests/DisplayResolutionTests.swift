import XCTest
@testable import notchi

@MainActor final class DisplayResolutionTests: XCTestCase {
    private let normal = ResolutionMode(width: 1440, height: 900, pixelWidth: 2880, pixelHeight: 1800, refresh: 6000)
    private let large = ResolutionMode(width: 1680, height: 1050, pixelWidth: 3360, pixelHeight: 2100, refresh: 6000)
    private func make(_ backend: FakeDisplayBackend, delay: TimeInterval = 15) -> (DisplayResolutionService, UserDefaults, String) {
        let name = "notchjp.display-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        backend.items = [ResolutionScreen(id: "screen-A", name: "Tela A", modes: [normal, large], current: normal, mirrored: false),
                         ResolutionScreen(id: "screen-B", name: "Tela B", modes: [normal, large], current: normal, mirrored: false)]
        return (DisplayResolutionService(backend: backend, defaults: defaults, rollbackDelay: delay), defaults, name)
    }
    func testFavoritesPersistPerMonitorWithoutChangingResolution() {
        let backend = FakeDisplayBackend()
        let (service, defaults, name) = make(backend)
        defer { defaults.removePersistentDomain(forName: name) }
        service.setFavorite(large, screen: "screen-A", enabled: true)
        service.setFavorite(large, screen: "screen-A", enabled: true)
        XCTAssertEqual(service.selectedModes(service.screens[0]), [large])
        XCTAssertTrue(service.selectedModes(service.screens[1]).isEmpty)
        let reloaded = DisplayResolutionService(backend: backend, defaults: defaults)
        XCTAssertTrue(reloaded.isFavorite(large, screen: "screen-A"))
        XCTAssertTrue(backend.applied.isEmpty)
        service.setFavorite(large, screen: "screen-A", enabled: false)
        XCTAssertTrue(service.selectedModes(service.screens[0]).isEmpty)
    }
    func testSwitchAndRevertTargetOnlyChosenMonitor() {
        let backend = FakeDisplayBackend()
        let (service, defaults, name) = make(backend)
        defer { defaults.removePersistentDomain(forName: name) }
        service.apply(large, screen: "screen-B", presentConfirmation: false)
        XCTAssertEqual(service.pendingScreen, "screen-B")
        XCTAssertEqual(backend.applied.map(\.screen), ["screen-B"])
        service.revert()
        XCTAssertEqual(backend.applied.map(\.mode), [large, normal])
        XCTAssertNil(service.pendingScreen)
    }
    func testConfirmKeepsModeAndDoesNotRevert() {
        let backend = FakeDisplayBackend()
        let (service, defaults, name) = make(backend)
        defer { defaults.removePersistentDomain(forName: name) }
        service.apply(large, screen: "screen-A", presentConfirmation: false)
        service.keep(); service.revert()
        XCTAssertEqual(backend.applied.count, 1)
        XCTAssertNil(service.deadline)
    }
    func testFailureDoesNotArmRollbackOrClaimSuccess() {
        let backend = FakeDisplayBackend()
        let (service, defaults, name) = make(backend)
        defer { defaults.removePersistentDomain(forName: name) }
        backend.fail = true
        service.apply(large, screen: "screen-A", presentConfirmation: false)
        XCTAssertNotNil(service.error)
        XCTAssertNil(service.pendingScreen)
    }
    func testDisconnectedAndMirroredScreensAreNotChanged() {
        let backend = FakeDisplayBackend()
        let (service, defaults, name) = make(backend)
        defer { defaults.removePersistentDomain(forName: name) }
        backend.items = [ResolutionScreen(id: "screen-A", name: "Tela A", modes: [normal, large], current: normal, mirrored: true)]
        service.apply(large, screen: "screen-B", presentConfirmation: false)
        XCTAssertNotNil(service.error)
        service.apply(large, screen: "screen-A", presentConfirmation: false)
        XCTAssertTrue(backend.applied.isEmpty)
    }
    func testTimeoutRestoresOriginalAutomatically() async throws {
        let backend = FakeDisplayBackend()
        let (service, defaults, name) = make(backend, delay: 0.02)
        defer { defaults.removePersistentDomain(forName: name) }
        service.apply(large, screen: "screen-A", presentConfirmation: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(backend.applied.map(\.mode), [large, normal])
        XCTAssertNil(service.pendingScreen)
    }
    func testModeIdentityDistinguishesHiDPIAndRefreshAndRemovesDuplicates() {
        let low = ResolutionMode(width: 1440, height: 900, pixelWidth: 1440, pixelHeight: 900, refresh: 6000)
        let faster = ResolutionMode(width: 1440, height: 900, pixelWidth: 2880, pixelHeight: 1800, refresh: 12000)
        XCTAssertNotEqual(normal.id, low.id)
        XCTAssertNotEqual(normal.id, faster.id)
        XCTAssertEqual(ResolutionMode.ordered([low, normal, large, normal, faster]), [faster, normal, low, large])
        XCTAssertTrue(normal.title.contains("HiDPI"))
    }
    func testCurrentModeAndUnavailableModeDoNotCauseWrite() {
        let backend = FakeDisplayBackend()
        let (service, defaults, name) = make(backend)
        defer { defaults.removePersistentDomain(forName: name) }
        service.apply(normal, screen: "screen-A", presentConfirmation: false)
        let unknown = ResolutionMode(width: 1, height: 1, pixelWidth: 1, pixelHeight: 1, refresh: 0)
        service.apply(unknown, screen: "screen-A", presentConfirmation: false)
        XCTAssertTrue(backend.applied.isEmpty)
    }
}

@MainActor private final class FakeDisplayBackend: DisplayResolutionBackend {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    var items: [ResolutionScreen] = []
    var applied: [(screen: String, mode: ResolutionMode)] = []
    var fail = false
    func screens() -> [ResolutionScreen] { items }
    func apply(screen: String, mode: ResolutionMode) throws {
        if fail { throw NSError(domain: "DisplayTest", code: 1) }
        applied.append((screen, mode))
        items = items.map { item in
            ResolutionScreen(id: item.id, name: item.name, modes: item.modes, current: item.id == screen ? mode : item.current, mirrored: item.mirrored)
        }
    }
}
