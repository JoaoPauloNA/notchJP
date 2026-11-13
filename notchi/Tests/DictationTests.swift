import AVFoundation
import Carbon
import XCTest
@testable import notchi

private final class MockTranscriptionProtocol: URLProtocol {
    nonisolated(unsafe) static var responseCode = 200
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DictationTests: XCTestCase {
    // MARK: Text formatting
    func testPercentageFormattingInPortugueseOnly() {
        let cases = [
            ("70 por cento", "70%"),
            ("De 5 por cento para 12,5 por cento!", "De 5% para 12,5%!"),
            ("-2,5 POR CENTO e +3.5 por cento", "-2,5% e +3.5%"),
            ("70 por centopeia", "70 por centopeia"),
            ("item70 por cento", "item70 por cento"),
            ("70\u{00a0}por\u{00a0}cento", "70%"),
        ]
        for (input, expected) in cases {
            let formatted = DictationTextFormatting.format(input, language: "pt-BR")
            XCTAssertEqual(formatted, expected, input)
            XCTAssertEqual(DictationTextFormatting.format(formatted, language: "pt-BR"), formatted, "idempotente")
        }
        XCTAssertEqual(DictationTextFormatting.format("70 por cento", language: "en-US"), "70 por cento")
    }

    func testSpokenNumbersBecomePercentages() {
        let cases = [
            ("setenta por cento", "70%"),
            ("Aumentou setenta por cento.", "Aumentou 70%."),
            ("vinte e cinco por cento", "25%"),
            ("cento e vinte por cento", "120%"),
            ("cem por cento", "100%"),
            ("um por cento do total", "1% do total"),
            ("doze vírgula cinco por cento", "12,5%"),
            ("dois vírgula zero cinco por cento", "2,05%"),
            ("De cinco por cento para quinze por cento!", "De 5% para 15%!"),
            ("Quero cinco laranjas, por cento nenhum", "Quero cinco laranjas, por cento nenhum"),
            ("setenta por centopeia", "setenta por centopeia"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DictationTextFormatting.format(input, language: "pt-BR"), expected, input)
        }
        XCTAssertEqual(DictationTextFormatting.format("setenta por cento", language: "en-US"), "setenta por cento")
        XCTAssertEqual(DictationTextFormatting.spokenInteger("cento e vinte e cinco"), 125)
        XCTAssertNil(DictationTextFormatting.spokenInteger("vinte banana"))
    }

    // MARK: Audio
    func testAudioPreparationTrimsQuietEdgesButKeepsInnerPauses() throws {
        let rate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let quiet = Array(repeating: Float(0), count: 16_000)
        let speech = Array(repeating: Float(0.01), count: 8_000) + quiet + Array(repeating: Float(-0.01), count: 8_000)
        let samples = quiet + speech + quiet
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("njp-audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            // The file is only finished when the writer goes away.
            let writer = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                                     AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            try writer.write(from: buffer)
        }
        let original = try Data(contentsOf: url)
        let prepared: URL?
        do { prepared = try DictationAudioPreparation.prepare(url) } catch { return XCTFail("prepare lançou: \(error)") }
        guard let output = prepared else { return XCTFail("prepare devolveu nil") }
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 41_600, "fala, pausa interna e 300 ms de margem")
        XCTAssertEqual(try Data(contentsOf: url), original, "o original continua para tentar de novo")
    }

    func testDigitalSilenceIsRejectedButQuietSpeechIsKept() throws {
        let samples = [Float](repeating: 0, count: 8_000)
        samples.withUnsafeBufferPointer {
            XCTAssertNil(DictationAudioPreparation.retainedFrames($0, sampleRate: 16_000))
        }
        let quiet = [Float](repeating: 0.0004, count: 8_000)
        quiet.withUnsafeBufferPointer {
            XCTAssertNotNil(DictationAudioPreparation.retainedFrames($0, sampleRate: 16_000))
        }
    }

    // MARK: Connections
    func testConnectionRulesAcceptHTTPSAndLoopbackOnly() throws {
        XCTAssertNoThrow(try DictationAPIConnection(endpoint: "https://api.openai.com/v1/audio/transcriptions"))
        XCTAssertNoThrow(try DictationAPIConnection(endpoint: "http://127.0.0.1:8080/inference", localOnly: true))
        XCTAssertThrowsError(try DictationAPIConnection(endpoint: "http://exemplo.com/x"))
        XCTAssertThrowsError(try DictationAPIConnection(endpoint: "https://exemplo.com/x", localOnly: true))
        XCTAssertThrowsError(try DictationAPIConnection(endpoint: "https://user:senha@exemplo.com/x"))
        XCTAssertThrowsError(try DictationAPIConnection(endpoint: "https://exemplo.com/x", key: "chave\nquebrada"))
    }

    func testTranscriptionRequestHasModelLanguageAndBearerKey() throws {
        var settings = DictationSettings()
        settings.provider = .api
        settings.apiEndpoint = "https://exemplo.com/v1/audio/transcriptions"
        settings.apiModel = "whisper-1"
        let request = try DictationAPI().transcriptionRequest(audio: Data(repeating: 1, count: 100), settings: settings, key: "abc")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\""))
        XCTAssertTrue(body.contains("whisper-1"))
        XCTAssertTrue(body.contains("name=\"language\""))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertThrowsError(try DictationAPI().transcriptionRequest(audio: Data(count: 10), settings: settings, key: ""), "áudio vazio")
        settings.apiModel = "  "
        XCTAssertThrowsError(try DictationAPI().transcriptionRequest(audio: Data(count: 100), settings: settings, key: ""), "sem modelo")
    }

    func testAPIReturnsTextAndExplainsHTTPErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTranscriptionProtocol.self]
        let api = DictationAPI(session: URLSession(configuration: config))
        var settings = DictationSettings()
        settings.provider = .api
        settings.apiEndpoint = "https://exemplo.com/v1/audio/transcriptions"
        MockTranscriptionProtocol.responseCode = 200
        MockTranscriptionProtocol.payload = Data(#"{"text":" olá mundo "}"#.utf8)
        let text = try await api.transcribe(audio: Data(count: 100), settings: settings, key: "k")
        XCTAssertEqual(text, "olá mundo")
        MockTranscriptionProtocol.responseCode = 401
        do { _ = try await api.transcribe(audio: Data(count: 100), settings: settings, key: "k"); XCTFail("deveria falhar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("recusou a chave"), error.localizedDescription) }
        MockTranscriptionProtocol.responseCode = 200
        MockTranscriptionProtocol.payload = Data(#"{"text":"   "}"#.utf8)
        do { _ = try await api.transcribe(audio: Data(count: 100), settings: settings, key: "k"); XCTFail("deveria falhar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Nenhuma fala"), error.localizedDescription) }
    }

    // MARK: Settings and shortcut
    func testSettingsFromAnOlderFileKeepDefaultsAndPainelFields() throws {
        let empty = try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.provider, DictationProvider.preferred)
        XCTAssertEqual(empty.vocabulary, [])
        XCTAssertEqual(empty.language, "pt-BR")
        XCTAssertTrue(empty.autoPaste)
        XCTAssertEqual(empty.shortcut, .standard)
        let old = try JSONDecoder().decode(DictationSettings.self, from: Data(#"{"provider":"whisper","correctWithPainel":true,"painelModel":"x"}"#.utf8))
        XCTAssertEqual(old.provider, .whisper)
        XCTAssertTrue(old.correctWithPainel)
        let roundTrip = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(roundTrip, old)
    }

    func testShortcutValidationAndDisplay() {
        XCTAssertNil(DictationShortcut.standard.validationError)
        XCTAssertEqual(DictationShortcut.standard.displayName, "⌃ ⇧ Espaço")
        XCTAssertNotNil(DictationShortcut(keyCode: 49, modifiers: DictationShortcut.shift).validationError, "sem Control ou Command")
        XCTAssertNotNil(DictationShortcut(keyCode: 49, modifiers: DictationShortcut.command).validationError, "um modificador só")
        XCTAssertNotNil(DictationShortcut(keyCode: 8, modifiers: DictationShortcut.command | DictationShortcut.shift).validationError, "⌘⇧C é de app")
        XCTAssertNil(DictationShortcut(keyCode: 47, modifiers: DictationShortcut.command).validationError, "ponto aceita um modificador")
    }

    func testLiveTextIsOnByDefaultAndSurvivesOldFiles() throws {
        XCTAssertTrue(DictationSettings().liveText)
        XCTAssertTrue(try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8)).liveText)
        var off = DictationSettings()
        off.liveText = false
        XCTAssertFalse(try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(off)).liveText)
    }

    func testVocabularyIsCleanedAndDeduplicated() {
        XCTAssertEqual(NJPDictationSettingsView.parseVocabulary(" notchJP, Hostinger ,, notchjp\nTCL "), ["notchJP", "Hostinger", "TCL"])
        XCTAssertEqual(NJPDictationSettingsView.parseVocabulary("  "), [])
    }

    func testVocabularySurvivesSavingAndLoading() throws {
        var settings = DictationSettings()
        settings.vocabulary = ["notchJP", "Hostinger"]
        let restored = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.vocabulary, ["notchJP", "Hostinger"])
    }

    func testTheNewEngineIsOfferedOnlyWhereItExists() {
        XCTAssertEqual(DictationProvider.selectable.contains(.analyzer), DictationProvider.analyzerSupported)
        XCTAssertTrue(DictationProvider.selectable.contains(.apple))
    }

    func testHotKeyHandlersLeaveEachOthersKeysAlone() {
        // The panel toggle must not claim the dictation key (and the other way round),
        // otherwise whichever handler was installed last swallows the event.
        XCTAssertNotEqual(DictationShortcutRegistration.signature, GlobalShortcutService.togglePanelHotKeyID.signature)
        XCTAssertFalse(GlobalShortcutService.isTogglePanelHotKey(signature: DictationShortcutRegistration.signature, id: 2))
        XCTAssertTrue(GlobalShortcutService.isTogglePanelHotKey(signature: GlobalShortcutService.togglePanelHotKeyID.signature,
                                                                id: GlobalShortcutService.togglePanelHotKeyID.id))
    }

    func testEngineMigrationHappensOnceAndOnlyFromTheClassicEngine() {
        typealias S = DictationSettings
        XCTAssertEqual(S.migratedProvider(current: .apple, analyzerSupported: true, alreadyMigrated: false), .analyzer)
        XCTAssertEqual(S.migratedProvider(current: .apple, analyzerSupported: true, alreadyMigrated: true), .apple, "já migrou")
        XCTAssertEqual(S.migratedProvider(current: .apple, analyzerSupported: false, alreadyMigrated: false), .apple, "macOS antigo")
        XCTAssertEqual(S.migratedProvider(current: .whisper, analyzerSupported: true, alreadyMigrated: false), .whisper, "escolha explícita")
        XCTAssertEqual(S.migratedProvider(current: .api, analyzerSupported: true, alreadyMigrated: false), .api)
    }

    func testPasteResultsExplainThemselves() {
        let all: [DictationPasteResult] = [.inserted, .shortcutSent, .permissionRequired, .noTarget, .focusChanged, .unavailable]
        XCTAssertEqual(Set(all.map(\.status)).count, all.count)
    }

    // MARK: Notch integration
    @MainActor
    func testControllerTurnsModelFlagsIntoNotchPhases() {
        let controller = DictationController.shared
        let model = controller.model
        model.isRecording = true
        guard case .recording = controller.phase else { return XCTFail("deveria estar gravando") }
        model.isRecording = false
        model.isProcessing = true
        XCTAssertEqual(controller.phase, .transcribing)
        model.error = nil
        model.canRetry = false
        model.isProcessing = false
        guard case .finished(_, let ok) = controller.phase else { return XCTFail("deveria ter terminado") }
        XCTAssertTrue(ok)
        model.error = nil
    }

    func testDictationAlertLabels() {
        let now = Date()
        XCTAssertEqual(NotchAlert.dictation(.recording(since: now.addingTimeInterval(-75))).label(now: now), "1:15")
        XCTAssertEqual(NotchAlert.dictation(.transcribing).label(now: now), "…")
        XCTAssertEqual(NotchAlert.dictation(.finished(at: now, ok: true)).label(now: now), "colado")
        XCTAssertEqual(NotchAlert.dictation(.finished(at: now, ok: false)).label(now: now), "falhou")
        XCTAssertTrue(NotchAlert.dictation(.recording(since: now)).ticksEverySecond)
        XCTAssertTrue(NotchAlert.dictation(.recording(since: now)).pulses)
        XCTAssertTrue(NotchAlert.dictation(.transcribing).animatesIcon)
    }
}

/// Real speech through the real engine. Needs a Portuguese voice and the system speech model, so it is
/// opt-in: run with `TEST_RUNNER_RUN_SPEECH_TESTS=1 xcodebuild test ...`.
@MainActor
final class DictationSpeechIntegrationTests: XCTestCase {
    private func speak(_ text: String, voice: String) throws -> URL {
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("njp-say-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        for (executable, arguments) in [("/usr/bin/say", ["-v", voice, "-o", aiff.path, text]),
                                        ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, executable)
        }
        try? FileManager.default.removeItem(at: aiff)
        return wav
    }

    func testLiveSessionShowsGrowingTextWhileTheAudioPlaysAndKeepsAFile() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SPEECH_TESTS"] == "1" else { throw XCTSkip("teste de fala é opt-in") }
        let source = try speak("Hoje eu quero ditar um texto maior para ver o resultado aparecendo enquanto eu falo. Aumentou trinta por cento.", voice: "Luciana")
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("njp-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: saved) }
        let texts = LiveTexts()
        guard let session = try await DictationEngines.live(
            language: "pt-BR", vocabulary: [], fileURL: saved, source: DictationFileSource(url: source),
            onText: { texts.add($0) }, onLevel: { _ in }) else { throw XCTSkip("exige macOS 26") }
        try await session.begin()
        try await Task.sleep(for: .seconds(9))
        let final = try await session.finish()
        let seen = texts.all
        XCTAssertGreaterThan(seen.count, 3, "deveria haver vários textos parciais")
        XCTAssertTrue(seen.contains { !$0.lowercased().contains("trinta") }, "o começo aparece antes do fim")
        XCTAssertTrue(final.lowercased().contains("ditar"), final)
        XCTAssertTrue(DictationTextFormatting.format(final, language: "pt-BR").contains("30%"), final)
        let size = (try FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 20_000, "a cópia para tentar de novo foi gravada")
    }

    func testAnalyzerTranscribesPortugueseSpeech() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SPEECH_TESTS"] == "1" else { throw XCTSkip("teste de fala é opt-in") }
        guard let engine = DictationEngines.analyzer() else { throw XCTSkip("exige macOS 26") }
        let url = try speak("O ditado funciona muito bem no meu computador. Aumentou setenta por cento.", voice: "Luciana")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.prepare(language: "pt-BR")
        let text = try await engine.transcribe(url: url, language: "pt-BR", vocabulary: [])
        let lowered = text.lowercased()
        XCTAssertTrue(lowered.contains("ditado"), text)
        XCTAssertTrue(lowered.contains("computador"), text)
        XCTAssertTrue(DictationTextFormatting.format(text, language: "pt-BR").contains("70%"), text)
    }
}

private final class LiveTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ text: String) { lock.lock(); values.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
