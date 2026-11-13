import SwiftUI
import AppKit
import Combine

enum ACMode: String, CaseIterable, Sendable {
    case cool, dry, fan, heat, auto
    var label: String { switch self { case .cool: AppLanguage.text("Resfriar"); case .dry: AppLanguage.text("Desumidificar"); case .fan: AppLanguage.text("Ventilar"); case .heat: AppLanguage.text("Aquecer"); case .auto: AppLanguage.text("Automático") } }
}
enum ACFan: String, CaseIterable, Sendable {
    case auto, low, medium, high
    var label: String { switch self { case .auto: AppLanguage.text("Automática"); case .low: AppLanguage.text("Baixa"); case .medium: AppLanguage.text("Média"); case .high: AppLanguage.text("Alta") } }
}
enum ACAirflow: String, CaseIterable, Sendable {
    case off, vertical, horizontal, both
    var label: String { switch self { case .off: "Parado"; case .vertical: "Vertical"; case .horizontal: "Horizontal"; case .both: "Ambos" } }
}
enum ACVerticalDirection: Int, CaseIterable, Sendable {
    case swingAll = 1, swingUp = 2, swingDown = 3, unspecified = 8
    case top = 9, upper = 10, middle = 11, lower = 12, bottom = 13
    static var choices: [Self] { allCases.filter { $0 != .unspecified } }
    var label: String {
        switch self {
        case .swingAll: "Oscilar tudo"
        case .swingUp: "Oscilar acima"
        case .swingDown: "Oscilar abaixo"
        case .unspecified: "Sem posição"
        case .top: "Fixar no topo"
        case .upper: "Fixar acima"
        case .middle: "Fixar no meio"
        case .lower: "Fixar abaixo"
        case .bottom: "Fixar na base"
        }
    }
    var isSwing: Bool { (1...3).contains(rawValue) }
}
enum ACHorizontalDirection: Int, CaseIterable, Sendable {
    case swingAll = 1, swingLeft = 2, swingMiddle = 3, swingRight = 4, unspecified = 8
    case left = 9, centerLeft = 10, middle = 11, centerRight = 12, right = 13
    static var choices: [Self] { allCases.filter { $0 != .unspecified } }
    var label: String {
        switch self {
        case .swingAll: "Oscilar tudo"
        case .swingLeft: "Oscilar esquerda"
        case .swingMiddle: "Oscilar centro"
        case .swingRight: "Oscilar direita"
        case .unspecified: "Sem posição"
        case .left: "Fixar esquerda"
        case .centerLeft: "Centro-esquerda"
        case .middle: "Fixar no centro"
        case .centerRight: "Centro-direita"
        case .right: "Fixar direita"
        }
    }
    var isSwing: Bool { (1...4).contains(rawValue) }
}
struct ACState: Sendable {
    var power: Bool
    var temperature: Double
    var roomTemperature: Double?
    var eco: Bool
    var mode: ACMode
    var fan: ACFan
    var sleep: Bool
    var airflow: ACAirflow
    var deviceName: String = AppLanguage.text("Ar-condicionado")
    var verticalDirection: ACVerticalDirection? = nil
    var horizontalDirection: ACHorizontalDirection? = nil
    var breeze: Bool? = nil
}
enum ACCommand: Sendable {
    case power(Bool), temperature(Double), eco(Bool), mode(ACMode), fan(ACFan), sleep(Bool), airflow(ACAirflow)
    case verticalDirection(ACVerticalDirection), horizontalDirection(ACHorizontalDirection), breeze(Bool)
}
/// One air conditioner of the account.
struct ACDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let online: Bool
}

@MainActor protocol ACBackend {
    var name: String { get }
    func configure(email: String, password: String, region: String) async throws
    func readState() async throws -> ACState
    func perform(_ command: ACCommand) async throws -> ACState
    /// Devices of the account. Backends for a single appliance return an empty list.
    func listDevices() async throws -> [ACDeviceInfo]
    func readState(deviceID: String) async throws -> ACState
    func perform(_ command: ACCommand, deviceID: String) async throws -> ACState
}

extension ACBackend {
    func listDevices() async throws -> [ACDeviceInfo] { [] }
    func readState(deviceID: String) async throws -> ACState { try await readState() }
    func perform(_ command: ACCommand, deviceID: String) async throws -> ACState { try await perform(command) }
}

@MainActor final class ACController: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    /// The selected device (or the only one).
    @Published private(set) var state: ACState?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var lastUpdated: Date?
    /// Every air conditioner of the account; empty for single-appliance backends.
    @Published private(set) var devices: [ACDeviceInfo] = []
    @Published private(set) var selectedDeviceID: String?
    /// Last known state of each device, selected or not.
    @Published private(set) var states: [String: ACState] = [:]
    @Published private(set) var deviceErrors: [String: String] = [:]
    let backend: any ACBackend
    private let deviceNames: ResidentialDeviceNames
    private var namesSubscription: AnyCancellable?
    init(backend: any ACBackend, initialState: ACState? = nil, deviceNames: ResidentialDeviceNames? = nil) {
        self.backend = backend; self.state = initialState; self.deviceNames = deviceNames ?? .shared
        namesSubscription = self.deviceNames.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func displayName(for device: ACDeviceInfo) -> String {
        deviceNames.name(for: "air:\(device.id)", fallback: device.name)
    }

    var originalSelectedName: String {
        selectedDeviceID.flatMap { device($0)?.name } ?? state?.deviceName ?? AppLanguage.text("Ar-condicionado")
    }

    var selectedDisplayName: String {
        guard let id = selectedDeviceID else { return originalSelectedName }
        return deviceNames.name(for: "air:\(id)", fallback: originalSelectedName)
    }

    func renameSelected(to name: String) {
        guard let id = selectedDeviceID else { return }
        deviceNames.rename("air:\(id)", to: name)
    }

    private var multiDevice: Bool { !devices.isEmpty }

    // MARK: Devices

    /// Reads the device list and keeps a valid selection.
    func refreshDevices() async {
        guard let list = try? await backend.listDevices(), !list.isEmpty else { return }
        devices = list
        let remembered = selectedDeviceID ?? (backend as? TCLBackend)?.selectedDeviceID
        let chosen = list.contains(where: { $0.id == remembered }) ? remembered : list.first?.id
        if chosen != selectedDeviceID { selectedDeviceID = chosen }
        syncBackendSelection()
    }

    func select(_ id: String) {
        guard devices.contains(where: { $0.id == id }), id != selectedDeviceID else { return }
        selectedDeviceID = id
        syncBackendSelection()
        state = states[id]
        error = deviceErrors[id]
        Task { await refresh() }
    }

    func device(_ id: String) -> ACDeviceInfo? { devices.first { $0.id == id } }

    /// Keeps the legacy single-selection of the TCL backend (used by settings) in step.
    private func syncBackendSelection() {
        if let tcl = backend as? TCLBackend, let id = selectedDeviceID, tcl.selectedDeviceID != id {
            tcl.selectedDeviceID = id
        }
    }

    private func read(_ id: String?) async throws -> ACState {
        if let id, multiDevice { return try await backend.readState(deviceID: id) }
        return try await backend.readState()
    }

    private func write(_ command: ACCommand, to id: String?) async throws -> ACState {
        if let id, multiDevice { return try await backend.perform(command, deviceID: id) }
        return try await backend.perform(command)
    }

    private func store(_ new: ACState, for id: String?) {
        if let id { states[id] = new; deviceErrors[id] = nil }
        if id == nil || id == selectedDeviceID { state = new; error = nil; lastUpdated = Date() }
    }

    private func fail(_ failure: Error, for id: String?) {
        if let id { deviceErrors[id] = failure.localizedDescription }
        if id == nil || id == selectedDeviceID { error = failure.localizedDescription }
    }

    // MARK: Reading

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await refreshDevices()
        let id = selectedDeviceID
        do { store(try await read(id), for: id) }
        catch { fail(error, for: id) }
    }

    /// Refreshes the devices that are not selected, one at a time, so the switcher shows their state.
    func refreshOthers() async {
        await refreshDevices()
        for device in devices where device.id != selectedDeviceID {
            guard !busy else { return }
            guard device.online else { deviceErrors[device.id] = AppLanguage.text("Desconectado"); continue }
            busy = true
            do { store(try await backend.readState(deviceID: device.id), for: device.id) }
            catch { fail(error, for: device.id) }
            busy = false
        }
    }

    // MARK: Commands

    /// Sends to the selected device.
    func send(_ command: ACCommand) {
        guard !busy, state != nil else { return }
        let id = selectedDeviceID
        busy = true
        Task {
            defer { busy = false }
            do { store(try await write(command, to: id), for: id) }
            catch { fail(error, for: id) }
        }
    }

    /// Like `send`, but waits for a running command and for this one to finish (used by scenes).
    /// `deviceID` targets one device of the account; nil means the selected one.
    @discardableResult
    func sendAndWait(_ command: ACCommand, to deviceID: String? = nil) async -> String? {
        var waited = 0
        while busy && waited < 40 {
            try? await Task.sleep(for: .milliseconds(150))
            waited += 1
        }
        let id = deviceID ?? selectedDeviceID
        if let deviceID, device(deviceID) == nil { return "Aparelho não encontrado nesta conta." }
        if multiDevice {
            guard let id, device(id)?.online == true else { return "Aparelho desconectado ou indisponível." }
        } else {
            guard state != nil else { return "Estado do aparelho indisponível." }
        }
        guard !busy else { return "O aparelho está ocupado." }
        busy = true
        defer { busy = false }
        do { store(try await write(command, to: id), for: id); return nil }
        catch { fail(error, for: id); return error.localizedDescription }
    }

    #if DEBUG
    /// Fills the controller for the preview renderer, which cannot wait for the network.
    func previewLoad(devices: [ACDeviceInfo], states: [String: ACState], selected: String) {
        self.devices = devices
        self.states = states
        selectedDeviceID = selected
        state = states[selected]
    }
    #endif

    private func loadInitialState() async throws {
        await refreshDevices()
        store(try await read(selectedDeviceID), for: selectedDeviceID)
    }

    func signIn(email: String, password: String, region: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await backend.configure(email: email, password: password, region: region)
            try await loadInitialState()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func signOut() {
        guard !busy, let tcl = backend as? TCLBackend else { return }
        tcl.signOut()
        state = nil
        states = [:]
        deviceErrors = [:]
        devices = []
        selectedDeviceID = nil
        lastUpdated = nil
        error = nil
    }
    func requestLoginCode(email: String, region: String) async -> Bool {
        guard !busy, let tcl = backend as? TCLBackend else { return false }
        busy = true
        defer { busy = false }
        do {
            let token = try await TCLHumanVerification.verify()
            try await tcl.sendLoginCode(email: email, region: region, validationToken: token)
            error = nil
            return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    func signInWithCode(email: String, code: String, region: String) async -> Bool {
        guard !busy, let tcl = backend as? TCLBackend else { return false }
        busy = true
        defer { busy = false }
        do {
            try await tcl.configure(email: email, code: code, region: region)
            try await loadInitialState()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
