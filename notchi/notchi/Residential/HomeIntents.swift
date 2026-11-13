import AppIntents
import Foundation

nonisolated struct HomeIntentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

nonisolated struct AirConditionerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Air conditioner")
    static let defaultQuery = AirConditionerQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
nonisolated struct AirConditionerQuery: EntityQuery {
    @MainActor func suggestedEntities() async throws -> [AirConditionerEntity] {
        guard let home = AppExperience.home else { return [] }
        await home.air.refreshDevices()
        return home.air.devices.map { AirConditionerEntity(id: $0.id, name: home.air.displayName(for: $0)) }
    }
    func entities(for identifiers: [String]) async throws -> [AirConditionerEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}
nonisolated struct HomeSceneEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Home scene")
    static let defaultQuery = HomeSceneQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
nonisolated struct HomeSceneQuery: EntityQuery {
    @MainActor func suggestedEntities() async throws -> [HomeSceneEntity] {
        AppExperience.home?.scenes.map { HomeSceneEntity(id: $0.id, name: $0.name) } ?? []
    }
    func entities(for identifiers: [String]) async throws -> [HomeSceneEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

nonisolated struct SetAirPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set air conditioner power"
    static let description = IntentDescription("Turn a configured TCL Home air conditioner on or off.")
    static let openAppWhenRun = true
    @Parameter(title: "Air conditioner") var device: AirConditionerEntity
    @Parameter(title: "Turn on") var power: Bool
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let home = try HomeIntentAccess.ready()
        await home.air.refreshDevices()
        if let failure = await home.air.sendAndWait(.power(power), to: device.id) { throw HomeIntentError(failure) }
        return .result(dialog: "Command accepted by the air conditioner.")
    }
}
nonisolated struct SetAirTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set air conditioner temperature"
    static let openAppWhenRun = true
    @Parameter(title: "Air conditioner") var device: AirConditionerEntity
    @Parameter(title: "Temperature in Celsius", inclusiveRange: (16, 32)) var temperature: Int
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (16...32).contains(temperature) else { throw HomeIntentError("Temperature must be between 16 and 32 °C.") }
        let home = try HomeIntentAccess.ready()
        await home.air.refreshDevices()
        if let failure = await home.air.sendAndWait(.temperature(Double(temperature)), to: device.id) { throw HomeIntentError(failure) }
        return .result(dialog: "Temperature command accepted.")
    }
}
nonisolated struct TelevisionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "LG TV")
    static let defaultQuery = TelevisionQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
nonisolated struct TelevisionQuery: EntityQuery {
    @MainActor func suggestedEntities() async throws -> [TelevisionEntity] {
        guard let tv = AppExperience.home?.tv, let device = tv.selectedDevice else { return [] }
        return [TelevisionEntity(id: device.id, name: tv.displayName)]
    }
    func entities(for identifiers: [String]) async throws -> [TelevisionEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}
nonisolated struct SetTelevisionPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set LG TV power"
    static let openAppWhenRun = true
    @Parameter(title: "TV") var device: TelevisionEntity
    @Parameter(title: "Turn on") var power: Bool
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let home = try HomeIntentAccess.ready()
        if let failure = await home.tv.performSceneAction(power ? .on : .off, input: nil, expectedID: device.id) { throw HomeIntentError(failure) }
        return .result(dialog: "Command accepted by the TV.")
    }
}
nonisolated struct RunHomeSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Run notchJP home scene"
    static let openAppWhenRun = true
    @Parameter(title: "Scene") var scene: HomeSceneEntity
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let home = try HomeIntentAccess.ready()
        guard let selected = home.scenes.first(where: { $0.id == scene.id }) else { throw HomeIntentError("This scene no longer exists. Choose another scene in Shortcuts.") }
        if let failure = selected.validationError { throw HomeIntentError(failure) }
        await home.run(selected)
        guard !home.results.isEmpty, home.results.allSatisfy(\.succeeded) else { throw HomeIntentError("The scene could not complete. Check the device results in notchJP.") }
        return .result(dialog: "Scene completed.")
    }
}
@MainActor enum HomeIntentAccess {
    static func ready() throws -> HomeAutomation {
        guard let home = AppExperience.home else { throw HomeIntentError("Open notchJP and configure your devices first.") }
        guard !home.running else { throw HomeIntentError("Another home action is still running. Try again shortly.") }
        return home
    }
}
