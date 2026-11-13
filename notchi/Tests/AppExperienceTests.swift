import XCTest
@testable import notchi

final class AppExperienceTests: XCTestCase {
    @MainActor func testProfileRoundTripRenameDeleteAndApplication() throws {
        let suite = "notchjp.profiles-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mixer = AppAudioMixer(defaults: defaults)
        let profiles = AudioProfiles(defaults: defaults)
        XCTAssertFalse(profiles.save(name: "  ", mixer: mixer))
        mixer.setVolume(0.35, for: "app.example")
        XCTAssertTrue(profiles.save(name: " Trabalho ", mixer: mixer))
        let restored = AudioProfiles(defaults: defaults)
        let profile = try XCTUnwrap(restored.profiles.first)
        XCTAssertEqual(profile.name, "Trabalho")
        restored.rename(profile.id, to: "Música")
        XCTAssertEqual(AudioProfiles(defaults: defaults).profiles.first?.name, "Música")
        mixer.setVolume(0.8, for: "app.example")
        mixer.apply(profile)
        XCTAssertEqual(mixer.level(for: "app.example").volume, 0.35)
        XCTAssertFalse(mixer.enabled)
        restored.delete(profile.id)
        XCTAssertTrue(AudioProfiles(defaults: defaults).profiles.isEmpty)
    }
    @MainActor func testDiagnosticExportUsesOnlyAllowedFields() throws {
        let report = AppDiagnosticReport(schemaVersion: 1, appVersion: "1.4.0", edition: "public", macOS: "15.0.0", displayCount: 2,
            mixerEnabled: true, mixerAppCount: 3, mixerErrorCount: 1, spotifyRunning: false, airDeviceCount: 2, airHasError: true, tvConnected: false, tvHasError: true)
        let data = try AppDiagnostics.encoded(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "appVersion", "edition", "macOS", "displayCount", "mixerEnabled", "mixerAppCount", "mixerErrorCount", "spotifyRunning", "airDeviceCount", "airHasError", "tvConnected", "tvHasError"]))
    }
    @MainActor func testHomeIntentsRequireConfiguredApp() {
        let old = AppExperience.home
        defer { AppExperience.home = old }
        AppExperience.home = nil
        XCTAssertThrowsError(try HomeIntentAccess.ready())
    }
}
