import Foundation
import Combine

nonisolated struct AudioProfile: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var enabled: Bool
    var levels: [String: AudioAppLevel]
    var destinations: [String: String]
}

@MainActor final class AudioProfiles: ObservableObject {
    nonisolated deinit {}
    static let shared = AudioProfiles()
    @Published private(set) var profiles: [AudioProfile]
    private let defaults: UserDefaults
    private static let key = "njp.audioMixer.profiles"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([AudioProfile].self, from: $0) } ?? []
    }
    @discardableResult func save(name: String, mixer: AppAudioMixer) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { return false }
        let profile = AudioProfile(name: name, enabled: mixer.enabled, levels: mixer.levels, destinations: mixer.destinations)
        profiles.append(profile); persist(); return true
    }
    func rename(_ id: String, to value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name; persist()
    }
    func delete(_ id: String) { profiles.removeAll { $0.id == id }; persist() }
    private func persist() { defaults.set(try? JSONEncoder().encode(profiles), forKey: Self.key) }
}
