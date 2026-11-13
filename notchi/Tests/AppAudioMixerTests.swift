import CoreAudio
import XCTest
@testable import notchi

final class AppAudioMixerTests: XCTestCase {
    /// Exercise the real callback with synthetic PCM, without capturing or playing audio.
    private func render(_ dsp: AppAudioDSP, input: [[Float]], channels: [UInt32], output: [[Float]], outputChannels: [UInt32]) -> [[Float]] {
        let source = AudioBufferList.allocate(maximumBuffers: input.count)
        let destination = AudioBufferList.allocate(maximumBuffers: output.count)
        let sourceData = input.map { samples -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        let destinationData = output.map { samples -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        defer {
            for pointer in sourceData + destinationData { pointer.deallocate() }
            source.unsafeMutablePointer.deallocate()
            destination.unsafeMutablePointer.deallocate()
        }
        for index in input.indices {
            source[index] = AudioBuffer(mNumberChannels: channels[index], mDataByteSize: UInt32(input[index].count * 4), mData: sourceData[index])
        }
        for index in output.indices {
            destination[index] = AudioBuffer(mNumberChannels: outputChannels[index], mDataByteSize: UInt32(output[index].count * 4), mData: destinationData[index])
        }
        dsp.render(input: source.unsafePointer, output: destination.unsafeMutablePointer)
        return output.indices.map { Array(UnsafeBufferPointer(start: destinationData[$0], count: output[$0].count)) }
    }

    @MainActor func testTabOrderRepairsDuplicatesUnknownIDsAndAddsNewTabs() {
        XCTAssertEqual(PanelTabs.normalized([6, 6, -1, 500, 2]), [6, 2, 0, 1, 3, 4, 5])
        XCTAssertEqual(PanelTabs.normalized([]), Array(0..<7))
    }

    func testMeterMeasuresEffectiveOutputAndResetsAfterReading() {
        let dsp = AppAudioDSP(gain: 0.5, channels: 1, planar: false, sampleRate: 48000)
        _ = render(dsp, input: [[1, -0.8]], channels: [1], output: [[0, 0]], outputChannels: [1])
        XCTAssertEqual(dsp.takePeak(), 0.5, accuracy: 0.0001)
        XCTAssertEqual(dsp.takePeak(), 0)
    }

    func testStereoAttenuationKeepsChannelsAndDoesNotCopyPhysicalMicrophone() {
        let dsp = AppAudioDSP(gain: 0.5, channels: 2, planar: false, sampleRate: 48000)
        let result = render(dsp, input: [[99, 99], [1, -1, 0.4, -0.4]], channels: [1, 2],
                            output: [[9, 9, 9, 9]], outputChannels: [2])
        XCTAssertEqual(result[0], [0.5, -0.5, 0.2, -0.2])
    }

    func testPlanarStereoAndShortOutputBuffer() {
        let dsp = AppAudioDSP(gain: 0.25, channels: 2, planar: true, sampleRate: 48000)
        let result = render(dsp, input: [[1, 0.5, 0.25], [-1, -0.5, -0.25]], channels: [1, 1],
                            output: [[9, 9], [9, 9]], outputChannels: [1, 1])
        XCTAssertEqual(result, [[0.25, 0.125], [-0.25, -0.125]])
    }

    func testMuteProducesSilenceAndClearsUnusedOutput() {
        let dsp = AppAudioDSP(gain: 0, channels: 1, planar: false, sampleRate: 48000)
        XCTAssertEqual(render(dsp, input: [[1, -1]], channels: [1], output: [[9, 9, 9, 9]], outputChannels: [1]), [[0, 0, 0, 0]])
    }

    func testVolumeChangeRampsWithoutAnInstantDiscontinuity() {
        let dsp = AppAudioDSP(gain: 1, channels: 1, planar: false, sampleRate: 1000)
        dsp.setGain(0)
        let result = render(dsp, input: [Array(repeating: 1, count: 12)], channels: [1],
                            output: [Array(repeating: 9, count: 12)], outputChannels: [1])[0]
        XCTAssertEqual(result[0], 0.9, accuracy: 0.0001)
        XCTAssertEqual(result[11], 0, accuracy: 0.0001)
        for pair in zip(result, result.dropFirst()) { XCTAssertLessThanOrEqual(abs(pair.0 - pair.1), 0.10001) }
    }

    func testMismatchedChannelLayoutOutputsSilenceInsteadOfReadingInvalidMemory() {
        let dsp = AppAudioDSP(gain: 1, channels: 2, planar: false, sampleRate: 48000)
        XCTAssertEqual(render(dsp, input: [[1, 1]], channels: [1], output: [[9, 9]], outputChannels: [2]), [[0, 0]])
    }

    func testUnsafeGainCannotAmplifyOrPropagateNaN() {
        XCTAssertEqual(AppAudioDSP.clamp(.nan), 1)
        XCTAssertEqual(AppAudioDSP.clamp(.infinity), 1)
        XCTAssertEqual(AppAudioDSP.clamp(-1), 0)
        XCTAssertEqual(AppAudioDSP.clamp(12), 1)
    }

    func testHelpersGroupWithOwningAppAndRespectBundleBoundaries() {
        let candidates = [(id: "com.example.Player", path: "/Applications/Player.app"),
                          (id: "com.example.Player.beta", path: "/Applications/Player beta.app")]
        XCTAssertEqual(AppAudioMixer.ownerID(bundleID: "helper.audio", bundlePath: "/Applications/Player.app/Contents/Frameworks/Helper.app", candidates: candidates), "com.example.Player")
        XCTAssertEqual(AppAudioMixer.ownerID(bundleID: "com.example.Player.beta.helper", bundlePath: nil, candidates: candidates), "com.example.Player.beta")
        XCTAssertEqual(AppAudioMixer.ownerID(bundleID: "com.example.PlayerTwo", bundlePath: nil, candidates: candidates), "com.example.PlayerTwo")
        XCTAssertEqual(AppAudioMixer.ownerID(bundleID: "helper", bundlePath: "/Applications/Player.app.other/Helper.app", candidates: candidates), "helper")
    }

    @MainActor func testLevelsPersistMuteRestoresPreviousVolumeAndDefaultsToDisabled() {
        let name = "notchjp.audio-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let mixer = AppAudioMixer(defaults: defaults)
        XCTAssertFalse(mixer.enabled)
        mixer.setVolume(0.4, for: "app")
        mixer.toggleMute("app")
        XCTAssertEqual(mixer.level(for: "app").gain, 0)
        let restored = AppAudioMixer(defaults: defaults)
        XCTAssertFalse(restored.enabled)
        XCTAssertTrue(restored.level(for: "app").muted)
        restored.toggleMute("app")
        XCTAssertEqual(restored.level(for: "app").gain, 0.4)
        restored.setVolume(0, for: "app")
        restored.toggleMute("app")
        XCTAssertEqual(restored.level(for: "app").gain, 1)
        restored.restoreAll()
        XCTAssertEqual(AppAudioMixer(defaults: defaults).level(for: "app").gain, 1)
    }

    @MainActor func testActivationSurvivesShutdownButExplicitDisablePersists() {
        let name = "notchjp.audio-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let mixer = AppAudioMixer(defaults: defaults)
        mixer.setEnabled(true)
        mixer.stop()
        XCTAssertFalse(mixer.enabled)
        let reopened = AppAudioMixer(defaults: defaults)
        defer { reopened.stop() }
        XCTAssertTrue(reopened.enabled)
        reopened.start()
        XCTAssertTrue(reopened.enabled)
        reopened.setEnabled(false)
        reopened.stop()
        let disabled = AppAudioMixer(defaults: defaults)
        defer { disabled.stop() }
        disabled.start()
        XCTAssertFalse(disabled.enabled)
    }
}
