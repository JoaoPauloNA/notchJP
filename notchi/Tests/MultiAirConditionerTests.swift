import XCTest
@testable import notchi

@MainActor
final class MultiAirConditionerTests: XCTestCase {
    /// Three air conditioners: two online, one offline.
    @MainActor private final class FakeAccount: ACBackend {
        let name = "conta de teste"
        var devices = [
            ACDeviceInfo(id: "jp", name: "Meu quarto", online: true),
            ACDeviceInfo(id: "mae", name: "Quarto da mamãe", online: true),
            ACDeviceInfo(id: "sala", name: "Sala", online: false),
        ]
        var states: [String: ACState] = [
            "jp": FakeAccount.make(temperature: 24),
            "mae": FakeAccount.make(temperature: 26),
            "sala": FakeAccount.make(temperature: 25),
        ]
        var sent: [(device: String, command: ACCommand)] = []
        var failing: Set<String> = []

        static func make(temperature: Double) -> ACState {
            ACState(power: true, temperature: temperature, roomTemperature: 29, eco: false, mode: .cool, fan: .auto,
                    sleep: false, airflow: .vertical)
        }

        func configure(email: String, password: String, region: String) async throws {}
        func listDevices() async throws -> [ACDeviceInfo] { devices }
        func readState() async throws -> ACState { throw TCLBackendError("Selecione um ar-condicionado na sua conta TCL Home.") }
        func perform(_ command: ACCommand) async throws -> ACState { try await readState() }
        func readState(deviceID: String) async throws -> ACState {
            if failing.contains(deviceID) { throw TCLBackendError("falhou \(deviceID)") }
            return states[deviceID]!
        }
        func perform(_ command: ACCommand, deviceID: String) async throws -> ACState {
            if failing.contains(deviceID) { throw TCLBackendError("falhou \(deviceID)") }
            sent.append((deviceID, command))
            var state = states[deviceID]!
            switch command {
            case .temperature(let value): state.temperature = value
            case .power(let value): state.power = value
            case .sleep(let value): state.sleep = value
            default: break
            }
            states[deviceID] = state
            return state
        }
    }

    private func controller() -> (ACController, FakeAccount) {
        let account = FakeAccount()
        return (ACController(backend: account), account)
    }

    func testDevicesAreListedAndTheFirstIsSelected() async {
        let (air, _) = controller()
        await air.refresh()
        XCTAssertEqual(air.devices.map(\.name), ["Meu quarto", "Quarto da mamãe", "Sala"])
        XCTAssertEqual(air.selectedDeviceID, "jp")
        XCTAssertEqual(air.state?.temperature, 24)
    }

    func testSelectingAnotherDeviceShowsItsOwnState() async {
        let (air, _) = controller()
        await air.refresh()
        air.select("mae")
        while air.busy || air.state?.temperature != 26 { try? await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(air.selectedDeviceID, "mae")
        XCTAssertEqual(air.state?.temperature, 26)
        XCTAssertEqual(air.states["jp"]?.temperature, 24, "o estado do outro aparelho continua guardado")
    }

    func testSelectingAnUnknownDeviceChangesNothing() async {
        let (air, _) = controller()
        await air.refresh()
        air.select("nao-existe")
        XCTAssertEqual(air.selectedDeviceID, "jp")
    }

    func testCommandsGoOnlyToTheChosenDevice() async {
        let (air, account) = controller()
        await air.refresh()
        await air.sendAndWait(.temperature(22), to: "mae")
        XCTAssertEqual(account.sent.map(\.device), ["mae"])
        XCTAssertEqual(account.states["jp"]?.temperature, 24)
        XCTAssertEqual(account.states["mae"]?.temperature, 22)
        XCTAssertEqual(air.states["mae"]?.temperature, 22)
        XCTAssertEqual(air.state?.temperature, 24, "o aparelho selecionado não mudou")
    }

    func testOfflineAndUnknownTargetsAreSkipped() async {
        let (air, account) = controller()
        await air.refresh()
        await air.sendAndWait(.temperature(20), to: "sala")
        await air.sendAndWait(.temperature(20), to: "fantasma")
        XCTAssertTrue(account.sent.isEmpty)
    }

    func testOthersAreRefreshedAndOfflineOnesAreFlagged() async {
        let (air, account) = controller()
        await air.refresh()
        account.states["mae"] = FakeAccount.make(temperature: 21)
        await air.refreshOthers()
        XCTAssertEqual(air.states["mae"]?.temperature, 21)
        XCTAssertEqual(air.deviceErrors["sala"], "Desconectado")
        XCTAssertNil(air.states["sala"])
    }

    func testOneFailingDeviceDoesNotBlockTheOthers() async {
        let (air, account) = controller()
        await air.refresh()
        account.failing = ["mae"]
        await air.refreshOthers()
        XCTAssertNotNil(air.deviceErrors["mae"])
        XCTAssertEqual(air.state?.temperature, 24)
        account.failing = []
        await air.sendAndWait(.temperature(23), to: "jp")
        XCTAssertEqual(account.states["jp"]?.temperature, 23)
    }

    func testSendToEachAppliesToEveryChosenDeviceAndNoOthers() async {
        let (air, account) = controller()
        await air.refresh()
        await air.sendAndWait(.temperature(24), toEach: ["jp", "mae"])
        XCTAssertEqual(account.sent.map(\.device), ["jp", "mae"])
    }

    func testNightSceneOnlyTouchesTheChosenAirConditionersAndNeverSwitchesOff() async {
        let (air, account) = controller()
        await air.refresh()
        let tv = LGTVController(store: LGTVPairingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), preview: true)
        let night = try! XCTUnwrap(ResidentialScene.all.first { $0.id == "night" })
        await night.run(air, tv, ["mae"])
        XCTAssertFalse(account.sent.isEmpty)
        XCTAssertTrue(account.sent.allSatisfy { $0.device == "mae" }, "a cena só podia tocar no quarto da mamãe")
        for entry in account.sent {
            if case .power(false) = entry.command { XCTFail("a cena desligou o ar") }
        }
        XCTAssertEqual(account.states["jp"]?.sleep, false)
    }

    func testSingleApplianceBackendsKeepWorkingWithoutADeviceList() async {
        @MainActor final class Single: ACBackend {
            let name = "um só"
            var temperature = 24.0
            func configure(email: String, password: String, region: String) async throws {}
            func readState() async throws -> ACState { FakeAccount.make(temperature: temperature) }
            func perform(_ command: ACCommand) async throws -> ACState {
                if case .temperature(let value) = command { temperature = value }
                return FakeAccount.make(temperature: temperature)
            }
        }
        let air = ACController(backend: Single())
        await air.refresh()
        XCTAssertTrue(air.devices.isEmpty)
        XCTAssertEqual(air.state?.temperature, 24)
        await air.sendAndWait(.temperature(22), toEach: [])
        XCTAssertEqual(air.state?.temperature, 22)
    }

    func testStateWithoutWindSpeedReadsAsAutomaticFan() throws {
        let state = try TCLShadowDecoder.decode(["powerSwitch": 1, "targetTemperature": 22, "workMode": 1], deviceName: "mae")
        XCTAssertEqual(state.fan, .auto)
        XCTAssertEqual(state.temperature, 22)
    }

    func testOutOfRangeWindSpeedStillFailsWithTheFieldName() {
        let values: [String: Any] = ["powerSwitch": 1, "targetTemperature": 22, "workMode": 1, "windSpeed": 9]
        XCTAssertThrowsError(try TCLShadowDecoder.decode(values, deviceName: "x")) { error in
            XCTAssertTrue(error.localizedDescription.contains("windSpeed=9"))
        }
    }

    func testLocalNamesSurviveRefreshAndRestartWithoutChangingCommandTargets() async throws {
        let suite = "notchjp-names-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeAccount()
        let air = ACController(backend: backend, deviceNames: ResidentialDeviceNames(defaults: defaults))
        await air.refresh()
        air.renameSelected(to: "  Ar do quarto  ")
        await air.refresh()
        XCTAssertEqual(air.selectedDisplayName, "Ar do quarto")
        XCTAssertEqual(air.displayName(for: try XCTUnwrap(air.device("mae"))), "Quarto da mamãe")
        XCTAssertEqual(backend.devices.first?.name, "Meu quarto")
        XCTAssertTrue(backend.sent.isEmpty, "Renomear não envia comandos ao aparelho")
        await air.sendAndWait(.temperature(22))
        XCTAssertEqual(backend.sent.map(\.device), ["jp"])

        let reopened = ACController(backend: backend, deviceNames: ResidentialDeviceNames(defaults: defaults))
        await reopened.refresh()
        XCTAssertEqual(reopened.selectedDisplayName, "Ar do quarto")
        reopened.renameSelected(to: " \n ")
        XCTAssertEqual(reopened.selectedDisplayName, "Meu quarto")
    }
}
