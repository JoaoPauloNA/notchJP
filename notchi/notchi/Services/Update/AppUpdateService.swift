import Foundation
import Combine

/// Public source builds have no configured binary update channel.
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    @Published private(set) var status = "Build público a partir do fonte. Atualize pelo repositório notchJP."
    func start() {}
    func check() {}
    func setAutomaticChecks(_ enabled: Bool) {}
    func setAutomaticDownloads(_ enabled: Bool) {}
}
