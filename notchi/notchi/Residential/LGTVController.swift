import Foundation
import Combine

nonisolated struct LGTVError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LGTVInput: Identifiable {
    let id: String
    let label: String
    let connected: Bool
}

struct LGTVPairing: Codable {
    let host: String
    let key: String
    var device: LGTVDevice?
    var wakeMAC: String?
    init(host: String, key: String, device: LGTVDevice? = nil, wakeMAC: String? = nil) {
        self.host = host; self.key = key; self.device = device; self.wakeMAC = wakeMAC
    }
}

/// Separate from the TCL session: TV keys never enter the source or app bundle.
struct LGTVPairingStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ControleAr/TV", isDirectory: true)
    }
    private var file: URL { directory.appendingPathComponent("pairing.json") }
    func load() throws -> LGTVPairing? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(LGTVPairing.self, from: Data(contentsOf: file))
    }
    func save(_ pairing: LGTVPairing) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(pairing).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum LGTVProtocol {
    static let permissions = ["LAUNCH", "CONTROL_AUDIO", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
        "READ_INPUT_DEVICE_LIST", "READ_INSTALLED_APPS", "CONTROL_MOUSE_AND_KEYBOARD", "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS"]
    nonisolated static func address(_ raw: String) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0...255).contains($0) } == true
        }) else { throw LGTVError(message: "Informe o endereço IPv4 da TV, por exemplo 192.168.1.100.") }
        let values = parts.compactMap { Int($0) }
        guard values[0] == 10 || (values[0] == 172 && (16...31).contains(values[1])) || (values[0] == 192 && values[1] == 168) else {
            throw LGTVError(message: "Use o endereço da TV na sua rede local.")
        }
        return values.map(String.init).joined(separator: ".")
    }
    static func registration(host: String, saved: LGTVPairing?, deviceID: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["pairingType": "PROMPT", "forcePairing": false,
            "manifest": ["manifestVersion": 1, "permissions": permissions,
                         "localizedAppNames": ["": "notchJP"]]]
        if let saved, saved.host == host, deviceID == nil || saved.device == nil || saved.device?.id == deviceID { payload["client-key"] = saved.key }
        return ["id": "register", "type": "register", "payload": payload]
    }
    static func relocatedPairing(_ saved: LGTVPairing, to device: LGTVDevice) -> LGTVPairing? {
        guard saved.device?.id == device.id || (saved.device == nil && saved.host == device.host) else { return nil }
        return LGTVPairing(host: device.host, key: saved.key, device: device, wakeMAC: saved.wakeMAC)
    }
    static func payload(from message: [String: Any]) throws -> [String: Any] {
        if message["type"] as? String == "error" {
            let detail = message["error"] as? String ?? "Comando recusado."
            if detail.lowercased().contains("rejected pairing") {
                throw LGTVError(message: "A TV recusou o pareamento. Clique em Conectar e aceite o pedido na tela da TV.")
            }
            throw LGTVError(message: "A TV respondeu: \(detail)")
        }
        guard let payload = message["payload"] as? [String: Any] else { throw LGTVError(message: "A TV enviou uma resposta incompleta.") }
        if payload["returnValue"] as? Bool == false { throw LGTVError(message: "A TV não aceitou o comando.") }
        return payload
    }
    static func volume(from payload: [String: Any]) throws -> (Int, Bool) {
        let data = payload["volumeStatus"] as? [String: Any] ?? payload
        guard let volume = data["volume"] as? Int, (0...100).contains(volume), let muted = data["muted"] as? Bool else {
            throw LGTVError(message: "A TV não informou o volume e o estado do som.")
        }
        return (volume, muted)
    }
    static func pointerURL(_ raw: String, host: String) throws -> URL {
        guard let url = URL(string: raw), url.host == host, url.scheme == "ws", url.port == 3000 else {
            throw LGTVError(message: "A TV informou um endereço de navegação inesperado.")
        }
        return url
    }
}

/// One serialized operation at a time. Every socket is closed, including on timeout.
@MainActor final class LGTVConnection {
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private var timedOut = false
    private var timeout: Task<Void, Never>?
    private(set) var helloMetadata: [String: Any] = [:]
    init(host: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
        socket = session.webSocketTask(with: URL(string: "ws://\(host):3000")!)
        socket.resume()
        setDeadline(seconds: 100)
    }
    func close() { timeout?.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
    func identify() async throws {
        setDeadline(seconds: 12)
        try await send(["id": "hello", "type": "hello", "payload": ["sdkVersion": "1.0", "deviceModel": "Mac",
            "OSVersion": "macOS", "resolution": "0x0", "appId": "local.jpna.controle-ar", "appName": "Controle Ar e TV", "appRegion": "BR"]])
        let response = try await receive()
        let payload = try LGTVProtocol.payload(from: response)
        let allowed = Set(["deviceOS", "deviceOSVersion", "deviceOSReleaseVersion", "deviceOSSDKVersion", "modelName", "protocolVersion", "sdkVersion"])
        helloMetadata = payload.filter { allowed.contains($0.key) }
        helloMetadata["availableFields"] = Array(payload.keys).filter { !["deviceUUID"].contains($0) }.sorted()
    }
    func pingMilliseconds() async throws -> Double {
        let start = Date()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return Date().timeIntervalSince(start) * 1000
    }
    private func setDeadline(seconds: Double) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.timedOut = true
            self?.socket.cancel(with: .goingAway, reason: nil)
        }
    }
    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func receive() async throws -> [String: Any] {
        do {
            let frame = try await socket.receive()
            let data: Data
            switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw LGTVError(message: "Resposta desconhecida.") }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LGTVError(message: "Resposta inválida da TV.") }
            return object
        } catch {
            if timedOut { throw LGTVError(message: "A TV não respondeu a tempo. Confira a rede e aceite o pedido de conexão na TV.") }
            throw error
        }
    }
    func register(host: String, store: LGTVPairingStore, device: LGTVDevice? = nil, onPrompt: () -> Void) async throws {
        try await send(LGTVProtocol.registration(host: host, saved: try store.load(), deviceID: device?.id))
        while true {
            let message = try await receive()
            let payload = try LGTVProtocol.payload(from: message)
            if message["type"] as? String == "registered" {
                guard let key = payload["client-key"] as? String, !key.isEmpty else { throw LGTVError(message: "A TV não forneceu a chave de pareamento.") }
                let saved = try store.load()
                let sameTV = (saved?.device != nil && device != nil) ? saved?.device?.id == device?.id : saved?.host == host
                let mac = LGTVWakeOnLAN.cachedMAC(host: host) ?? (sameTV ? saved?.wakeMAC : nil)
                try store.save(LGTVPairing(host: host, key: key, device: device ?? saved?.device, wakeMAC: mac))
                setDeadline(seconds: 12)
                return
            }
            if payload["pairingType"] != nil { onPrompt() }
        }
    }
    func request(_ uri: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        setDeadline(seconds: 12)
        let id = UUID().uuidString
        try await send(["id": id, "type": "request", "uri": "ssap://" + uri, "payload": payload])
        while true {
            let message = try await receive()
            if message["id"] as? String == id { return try LGTVProtocol.payload(from: message) }
        }
    }
    func button(_ name: String, host: String) async throws {
        let result = try await request("com.webos.service.networkinput/getPointerInputSocket")
        guard let raw = result["socketPath"] as? String else { throw LGTVError(message: "Navegação indisponível nesta TV.") }
        let pointer = session.webSocketTask(with: try LGTVProtocol.pointerURL(raw, host: host))
        pointer.resume()
        defer { pointer.cancel(with: .normalClosure, reason: nil) }
        try await pointer.send(.string("type:button\nname:\(name)\n\n"))
        // This protocol has no command acknowledgement. A successful send is not a state readback.
        try await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor final class LGTVController: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    @Published var host: String
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var waking = false
    @Published private(set) var volume: Int?
    @Published private(set) var muted = false
    @Published private(set) var model = "LG webOS TV"
    @Published private(set) var inputs: [LGTVInput] = []
    @Published private(set) var error: String?
    @Published private(set) var message = "Conecte sua TV pela rede Wi-Fi."
    private let store: LGTVPairingStore
    private let deviceNames: ResidentialDeviceNames
    private var namesSubscription: AnyCancellable?
    @Published private(set) var selectedDevice: LGTVDevice?
    @Published private(set) var foundDevices: [LGTVDevice] = []
    init(store: LGTVPairingStore? = nil, preview: Bool = false, deviceNames: ResidentialDeviceNames? = nil) {
        self.store = store ?? LGTVPairingStore()
        self.deviceNames = deviceNames ?? .shared
        let saved = try? self.store.load()
        selectedDevice = saved?.device
        host = saved?.host ?? UserDefaults.standard.string(forKey: "lgTVHost") ?? ""
        namesSubscription = self.deviceNames.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if preview {
            connected = true; volume = 8; model = "32LM625BPSB"; message = "Conectado pela rede"
            inputs = (1...3).map { LGTVInput(id: "HDMI_\($0)", label: "HDMI \($0)", connected: false) }
        }
    }
    var originalName: String { selectedDevice?.name ?? "TV LG" }
    var displayName: String {
        guard let device = selectedDevice else { return originalName }
        return displayName(for: device)
    }
    func displayName(for device: LGTVDevice) -> String {
        deviceNames.name(for: "tv:\(device.id)", fallback: device.name)
    }
    func rename(to name: String) {
        guard let device = selectedDevice else { return }
        deviceNames.rename("tv:\(device.id)", to: name)
    }
    private func resolveDevice(search: Bool, selected: LGTVDevice?) async throws -> LGTVDevice {
        if let selected {
            let verified = try await LGTVDiscovery.describe(selected.descriptionURL)
            guard verified.id == selected.id else { throw LGTVError(message: "A identidade da TV selecionada mudou. Faça uma nova busca.") }
            return verified
        }
        let saved = try store.load()
        let address = search ? ((try? LGTVProtocol.address(host)) ?? saved?.host ?? "") : try LGTVProtocol.address(host)
        // Check the unique identity before using a saved key at a cached address.
        if !search {
            let url: URL
            if let device = saved?.device, device.host == address { url = device.descriptionURL }
            else { url = URL(string: "http://\(address):1540/")! }
            if let current = try? await LGTVDiscovery.describe(url),
               saved?.device == nil || current.id == saved?.device?.id || address != saved?.host {
                return current
            }
        }
        message = "Buscando a TV na rede…"
        let devices = try await LGTVDiscovery.find()
        foundDevices = devices
        if let id = saved?.device?.id, let same = devices.first(where: { $0.id == id }) { return same }
        if let sameAddress = devices.first(where: { $0.host == address }), saved?.device == nil { return sameAddress }
        // Never silently pair a different TV when the known one is missing.
        if saved?.device == nil, devices.count == 1 { return devices[0] }
        if devices.count > 1 { throw LGTVError(message: "Há mais de uma TV LG na rede. Escolha sua TV nos ajustes.") }
        throw LGTVError(message: "A TV não respondeu. Se estiver desligada, use Ligar TV. Se já estiver ligada, confira a rede e os ajustes de conexão.")
    }
    @discardableResult
    private func run(search: Bool = false, selecting: LGTVDevice? = nil, identify: Bool = false, _ action: @escaping (LGTVConnection, String) async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil
        message = connected ? "Atualizando TV…" : "Conectando à TV…"
        defer { busy = false }
        var connection: LGTVConnection?
        do {
            let device = try await resolveDevice(search: search, selected: selecting)
            let address = device.host
            if let saved = try store.load(), let relocated = LGTVProtocol.relocatedPairing(saved, to: device) {
                // Reuse a key at a new IP only after matching the TV's stable UPnP identity.
                try store.save(relocated)
            }
            let active = LGTVConnection(host: address); connection = active
            if identify { try await active.identify() }
            try await active.register(host: address, store: store, device: device) { self.message = "Aceite o pedido de conexão na TV." }
            UserDefaults.standard.set(address, forKey: "lgTVHost")
            try await action(active, address)
            selectedDevice = device
            host = address; connected = true; message = "Conectado pela rede"
        } catch {
            // Preserve reported values as a reference, while disabling commands until reconnect.
            connected = false
            if let failure = error as? URLError {
                switch failure.code {
                case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut:
                    self.error = "Não foi possível acessar a TV em \(host). Confira se ela está ligada, na mesma rede do Mac, e se o IP continua correto."
                default: self.error = "Falha na conexão com a TV: \(failure.localizedDescription)"
                }
            } else { self.error = error.localizedDescription }
            message = "Sem conexão com a TV"
        }
        connection?.close()
        return error == nil
    }
    func refresh(search: Bool = false, selecting: LGTVDevice? = nil) async {
        await run(search: search, selecting: selecting) { connection, _ in
            let result = try await connection.request("audio/getVolume")
            (self.volume, self.muted) = try LGTVProtocol.volume(from: result)
            if let info = try? await connection.request("system/getSystemInfo"), let name = info["modelName"] as? String { self.model = name }
            if let list = try? await connection.request("tv/getExternalInputList"), let devices = list["devices"] as? [[String: Any]] {
                self.inputs = devices.compactMap { item in
                    guard let id = item["id"] as? String, let label = item["label"] as? String else { return nil }
                    return LGTVInput(id: id, label: label, connected: item["connected"] as? Bool ?? false)
                }
            }
        }
    }
    func selectDevice(_ device: LGTVDevice) async {
        guard !busy else { return }
        // This is an explicit selection, so a new TV will request its own on-screen pairing.
        await refresh(selecting: device)
    }
    func wake() async {
        guard !busy, !waking, !connected else { return }
        waking = true
        error = nil
        defer { waking = false }
        do {
            guard var saved = try store.load() else {
                throw LGTVError(message: "Conecte à TV uma vez enquanto ela estiver ligada para salvar o endereço de ativação.")
            }
            guard let mac = saved.wakeMAC ?? LGTVWakeOnLAN.cachedMAC(host: saved.host) else {
                throw LGTVError(message: "O endereço MAC da TV ainda não foi salvo. Conecte uma vez com ela ligada ou informe o MAC nos ajustes.")
            }
            saved.wakeMAC = mac
            try store.save(saved)
            host = saved.host
            try LGTVWakeOnLAN.send(mac: mac, host: saved.host)
            for _ in 0..<4 {
                message = "Ligando TV… aguardando conexão."
                try await Task.sleep(for: .seconds(3))
                await refresh()
                if connected { return }
            }
            throw LGTVError(message: "O comando para ligar foi enviado, mas a TV não respondeu. Ative ‘Ligar via Wi-Fi’ em ‘TV ligada com dispositivo móvel’ nas configurações da LG e mantenha a TV na tomada.")
        } catch {
            self.error = error.localizedDescription
            message = "TV sem conexão"
        }
    }

    func saveWakeMAC(_ mac: String) throws {
        _ = try LGTVWakeOnLAN.magicPacket(mac: mac)
        guard var saved = try store.load() else {
            throw LGTVError(message: "Faça primeiro o pareamento com a TV ligada.")
        }
        saved.wakeMAC = mac
        try store.save(saved)
    }

    var wakeMAC: String { (try? store.load())?.wakeMAC ?? "" }


    /// Await every scene command and reject a replacement TV even if it inherited the same IP.
    func performSceneAction(_ action: HomeTVAction, input: String?, expectedID: String) async -> String? {
        guard selectedDevice?.id == expectedID else { return "A TV desta ação não é a TV pareada." }
        guard !busy, !waking else { return "A TV está ocupada." }
        if action == .off {
            let accepted = await run { connection, _ in _ = try await connection.request("system/turnOff") }
            if accepted { connected = false; message = "Comando para desligar aceito pela TV." }
            return accepted ? nil : (error ?? "Não foi possível desligar a TV.")
        }
        await refresh()
        if !connected { await wake() }
        guard connected else { return error ?? "A TV não respondeu." }
        if action == .input {
            await refresh()
            guard let input, inputs.contains(where: { $0.id == input }) else { return "Entrada indisponível nesta TV." }
            let accepted = await run { connection, _ in _ = try await connection.request("tv/switchInput", payload: ["inputId": input]) }
            return accepted ? nil : (error ?? "Não foi possível trocar a entrada.")
        }
        return nil
    }
    func changeVolume(_ delta: Int) {
        Task { await run { connection, _ in
            _ = try await connection.request(delta > 0 ? "audio/volumeUp" : "audio/volumeDown")
            (self.volume, self.muted) = try LGTVProtocol.volume(from: await connection.request("audio/getVolume"))
        } }
    }
    func setVolume(_ value: Int) {
        Task { await run { connection, _ in
            _ = try await connection.request("audio/setVolume", payload: ["volume": min(100, max(0, value))])
            (self.volume, self.muted) = try LGTVProtocol.volume(from: await connection.request("audio/getVolume"))
        } }
    }
    func toggleMute() {
        let next = !muted
        Task { await run { connection, _ in
            _ = try await connection.request("audio/setMute", payload: ["mute": next])
            (self.volume, self.muted) = try LGTVProtocol.volume(from: await connection.request("audio/getVolume"))
        } }
    }
    func button(_ name: String) {
        guard ["UP", "DOWN", "LEFT", "RIGHT", "ENTER", "HOME", "BACK"].contains(name) else { return }
        Task { await run { connection, host in
            if name == "HOME" {
                try await connection.button("BACK", host: host)
                try await Task.sleep(for: .milliseconds(250))
                _ = try await connection.request("system.launcher/launch", payload: ["id": "com.jpna.casa"])
            } else {
                try await connection.button(name, host: host)
            }
        } }
    }
    /// Turns the TV off over the network (webOS `system/turnOff`).
    func turnOff() {
        Task { await run { connection, _ in _ = try await connection.request("system/turnOff") } }
    }
    func switchInput(_ id: String) {
        guard inputs.contains(where: { $0.id == id }) else { return }
        Task { await run { connection, _ in _ = try await connection.request("tv/switchInput", payload: ["inputId": id]) } }
    }
}
