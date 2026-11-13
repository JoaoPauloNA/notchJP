import Foundation
import Combine

nonisolated enum HomeTVAction: String, Codable, CaseIterable { case none, on, off, input }
nonisolated struct HomeScene: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "Nova cena"
    var airIDs: [String] = []
    var temperature = 24
    var mode = "cool"
    var fan = "auto"
    var turnAirOn = false
    var sleep = false
    var eco = false
    var tvID: String?
    var tvAction = HomeTVAction.none
    var input: String?
    var shortcut: String?
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Dê um nome à cena." }
        if airIDs.isEmpty && tvAction == .none { return "Escolha pelo menos um aparelho." }
        if !(16...32).contains(temperature) { return "A temperatura deve ficar entre 16 e 32 °C." }
        if !["cool", "dry", "fan", "heat", "auto"].contains(mode) || !["auto", "low", "medium", "high"].contains(fan) { return "Modo ou ventilação inválidos." }
        if tvAction != .none && tvID == nil { return "Conecte a TV antes de incluí-la na cena." }
        if tvAction == .input && (input ?? "").isEmpty { return "Escolha a entrada da TV." }
        return nil
    }
}
nonisolated struct HomeActionResult: Identifiable, Equatable {
    var id: String { deviceID }
    let deviceID: String
    let name: String
    let error: String?
    var succeeded: Bool { error == nil }
}
nonisolated struct HomeTimer: Codable, Identifiable, Equatable {
    enum Action: String, Codable { case tvOff, airTemperature }
    enum Status: String, Codable { case pending, running, succeeded, failed, missed, cancelled }
    var id = UUID().uuidString
    let deviceID: String
    let deviceName: String
    let deadline: Date
    let action: Action
    var temperature = 24
    var status = Status.pending
    var detail: String?
}

@MainActor final class HomeAutomation: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    @Published private(set) var scenes: [HomeScene]
    @Published private(set) var favorites: Set<String>
    @Published private(set) var timers: [HomeTimer]
    @Published private(set) var results: [HomeActionResult] = []
    @Published private(set) var running = false
    @Published var editorOpen = false
    @Published var message: String?
    let air: ACController
    let tv: LGTVController
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()
    private var ticker: Timer?
    private var started = false
    private var shortcuts: HomeSceneShortcuts?
    private let executor: ((HomeScene) async -> [HomeActionResult])?

    init(air: ACController, tv: LGTVController, defaults: UserDefaults = .standard,
         executor: ((HomeScene) async -> [HomeActionResult])? = nil) {
        self.air = air; self.tv = tv; self.defaults = defaults; self.executor = executor
        scenes = Self.load([HomeScene].self, key: "njp.home.scenes", defaults: defaults) ?? []
        favorites = Set(defaults.stringArray(forKey: "njp.home.favorites") ?? [])
        timers = Self.load([HomeTimer].self, key: "njp.home.timers", defaults: defaults) ?? []
        air.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        tv.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private func persist() {
        defaults.set(try? JSONEncoder().encode(scenes), forKey: "njp.home.scenes")
        defaults.set(Array(favorites).sorted(), forKey: "njp.home.favorites")
        defaults.set(try? JSONEncoder().encode(timers), forKey: "njp.home.timers")
    }
    func start(now: Date = Date()) {
        guard !started else { return }
        started = true
        recoverTimers(now: now)
        shortcuts = HomeSceneShortcuts { [weak self] id in
            guard let self, let scene = self.scenes.first(where: { $0.id == id }) else { return }
            Task { await self.run(scene) }
        }
        reloadShortcuts()
        armTimer()
    }
    private func armTimer() {
        ticker?.invalidate(); ticker = nil
        guard started, let next = timers.filter({ $0.status == .pending }).map(\.deadline).min() else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        ticker?.tolerance = 0.2
    }
    func recoverTimers(now: Date) {
        for index in timers.indices where timers[index].status == .running || (timers[index].status == .pending && timers[index].deadline <= now) {
            timers[index].status = .missed
            timers[index].detail = "Não executado: o app estava fechado ou a execução foi interrompida."
        }
        persist()
    }
    func stop() { started = false; ticker?.invalidate(); ticker = nil; shortcuts?.stop(); shortcuts = nil }
    private func reloadShortcuts() {
        if let failures = shortcuts?.reload(scenes), !failures.isEmpty { message = failures.joined(separator: "\n") }
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        persist()
    }
    @discardableResult func save(_ scene: HomeScene) -> String? {
        if let error = scene.validationError { return error }
        if let key = scene.shortcut {
            guard let shortcut = GlobalShortcut(rawValue: key), (1...9).contains(where: { HomeSceneShortcuts.shortcut(slot: $0) == shortcut }) else { return "Atalho inválido." }
            if shortcut == AppSettings.panelToggleShortcut || scenes.contains(where: { $0.id != scene.id && $0.shortcut == key }) { return "Este atalho já está em uso no notchJP." }
        }
        var value = scene; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = scenes.firstIndex(where: { $0.id == value.id }) { scenes[index] = value } else { scenes.append(value) }
        persist(); reloadShortcuts(); return nil
    }
    func delete(_ id: String) { scenes.removeAll { $0.id == id }; persist(); reloadShortcuts() }
    func run(_ scene: HomeScene) async {
        guard !running else { message = "Aguarde a ação atual terminar."; return }
        results = []
        if let error = scene.validationError { message = error; return }
        running = true; message = nil
        defer { running = false }
        results = await execute(scene)
    }
    private func execute(_ scene: HomeScene) async -> [HomeActionResult] {
        if let executor { return await executor(scene) }
        var output: [HomeActionResult] = []
        if !scene.airIDs.isEmpty { await air.refreshDevices() }
        for id in Set(scene.airIDs).sorted() {
            let name = air.device(id).map { air.displayName(for: $0) } ?? "Ar indisponível"
            var commands: [ACCommand] = []
            if scene.turnAirOn { commands.append(.power(true)) }
            commands += [.mode(ACMode(rawValue: scene.mode) ?? .cool), .temperature(Double(scene.temperature)),
                         .fan(ACFan(rawValue: scene.fan) ?? .auto), .sleep(scene.sleep), .eco(scene.eco)]
            var failure: String?
            for command in commands {
                if let error = await air.sendAndWait(command, to: id) { failure = error; break }
            }
            output.append(HomeActionResult(deviceID: "air:" + id, name: name, error: failure))
        }
        if scene.tvAction != .none, let id = scene.tvID {
            let error = await tv.performSceneAction(scene.tvAction, input: scene.input, expectedID: id)
            output.append(HomeActionResult(deviceID: "tv:" + id, name: tv.displayName, error: error))
        }
        return output
    }
    @discardableResult func schedule(_ timer: HomeTimer, now: Date = Date()) -> String? {
        guard timer.deadline > now, timer.deadline.timeIntervalSince(now) <= 86400 else { return "Escolha um prazo de até 24 horas." }
        guard timer.action != .airTemperature || (16...32).contains(timer.temperature) else { return "Temperatura inválida." }
        timers.removeAll { [.succeeded, .cancelled, .missed, .failed].contains($0.status) && $0.deadline < now.addingTimeInterval(-86400) }
        guard timers.filter({ $0.status == .pending }).count < 20 else { return "Limite de 20 temporizadores ativos." }
        timers.append(timer); persist(); armTimer(); return nil
    }
    func cancel(_ id: String) {
        guard let index = timers.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return }
        timers[index].status = .cancelled; persist(); armTimer()
    }
    func tick(now: Date = Date()) async {
        defer { armTimer() }
        guard !running, let index = timers.firstIndex(where: { $0.status == .pending && $0.deadline <= now }) else { return }
        let item = timers[index]
        // After sleep, never execute an old physical action unexpectedly.
        guard now.timeIntervalSince(item.deadline) < 60 else {
            timers[index].status = .missed; timers[index].detail = "Prazo perdido; o Mac pode ter estado em repouso."; persist(); return
        }
        running = true; timers[index].status = .running; persist()
        defer { running = false }
        let failure: String?
        if item.action == .tvOff {
            failure = await tv.performSceneAction(.off, input: nil, expectedID: item.deviceID)
        } else {
            await air.refreshDevices()
            failure = await air.sendAndWait(.temperature(Double(item.temperature)), to: item.deviceID)
        }
        if let current = timers.firstIndex(where: { $0.id == item.id }) {
            timers[current].status = failure == nil ? .succeeded : .failed
            timers[current].detail = failure ?? "Comando aceito pelo aparelho."
        }
        persist()
    }
    func startFocus(minutes: Int, sceneID: String?) async {
        guard !running else { message = "Aguarde a ação atual terminar."; return }
        if let sceneID {
            guard let scene = scenes.first(where: { $0.id == sceneID }) else { message = "Cena não encontrada."; return }
            await run(scene)
            guard !results.isEmpty, results.allSatisfy(\.succeeded) else { message = "O foco não iniciou: confira o resultado da cena."; return }
        }
        FocusTimerService.shared.start(minutes: minutes)
        message = "Foco iniciado por \(minutes) minutos."
    }
}
