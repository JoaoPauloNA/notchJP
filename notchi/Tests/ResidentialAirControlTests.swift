import XCTest
@testable import notchi

@MainActor
final class ResidentialAirControlTests: XCTestCase {
    func testHouseButtonTogglesBetweenOverviewAndResidential() {
        var mode = NotchDashboardMode.overview
        mode.toggleResidential()
        XCTAssertEqual(mode, .residential)
        mode.toggleResidential()
        XCTAssertEqual(mode, .overview)
    }

    func testDisconnectedControlsDoNotSendCommands() async {
        let backend = AirBackendStub()
        let controller = ACController(backend: backend)
        controller.send(.power(true))
        XCTAssertEqual(backend.writes, 0)
        XCTAssertFalse(controller.busy)
    }

    func testRefreshingOnlyReadsDeviceState() async {
        let backend = AirBackendStub()
        let controller = ACController(backend: backend)
        await controller.refresh()
        XCTAssertEqual(controller.state?.temperature, 24)
        XCTAssertEqual(backend.reads, 1)
        XCTAssertEqual(backend.writes, 0)
        XCTAssertNil(controller.error)
    }

    func testCommandLocksControlsUntilConfirmedStateArrives() async {
        let backend = AirBackendStub()
        let controller = ACController(backend: backend, initialState: backend.value)
        controller.send(.temperature(26))
        XCTAssertTrue(controller.busy)
        controller.send(.power(false))
        for _ in 0..<100 where controller.busy { await Task.yield() }
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(backend.writes, 1)
        XCTAssertEqual(controller.state?.temperature, 26)
        XCTAssertEqual(controller.state?.power, true)
    }

    func testFailedCommandKeepsLastConfirmedStateAndShowsError() async {
        let backend = AirBackendStub()
        backend.fail = true
        let controller = ACController(backend: backend, initialState: backend.value)
        controller.send(.temperature(26))
        for _ in 0..<100 where controller.busy { await Task.yield() }
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.state?.temperature, 24)
        XCTAssertNotNil(controller.error)
    }

    func testTCLRoutesAndArtworkAreBundled() throws {
        XCTAssertTrue(try TCLAccountRoute.lookup("BR").host.hasPrefix("https://"))
        XCTAssertFalse(ApplianceArtwork.svg(running: true, temperature: 24, airflow: .vertical).isEmpty)
        XCTAssertNotNil(Bundle.main.url(forResource: "vertical-1", withExtension: "png"))
        XCTAssertNotNil(Bundle.main.url(forResource: "horizontal-11", withExtension: "png"))
    }
}

@MainActor
private final class AirBackendStub: ACBackend {
    let name = "Test"
    var reads = 0
    var writes = 0
    var fail = false
    var value = ACState(power: true, temperature: 24, roomTemperature: 27, eco: false,
                        mode: .cool, fan: .auto, sleep: false, airflow: .off)
    func configure(email: String, password: String, region: String) async throws { }
    func readState() async throws -> ACState { reads += 1; return value }
    func perform(_ command: ACCommand) async throws -> ACState {
        writes += 1
        if fail { throw TCLBackendError("Sem conexão") }
        if case let .temperature(temperature) = command { value.temperature = temperature }
        return value
    }
}
