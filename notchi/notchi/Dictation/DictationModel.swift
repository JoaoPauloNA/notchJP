// Ported from BlabberType (MIT, by the same author). The Painel CLI review step was left out.
import AppKit
import AVFoundation
import Combine
import Security
import Darwin

struct DictationStorage {
    let root: URL
    init(root: URL? = nil) {
        let accountHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        self.root = root ?? URL(fileURLWithPath: accountHome).appendingPathComponent("Library/Application Support/Ditado")
    }
    /// Plain text next to the JSON files (0600).
    func saveText(_ text: String, name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent(name)
        try Data((ISO8601DateFormatter().string(from: Date()) + "  " + text + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
    }
}

enum DictationKeychain {
    private static func query(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.ditado.transcription",
         kSecAttrAccount as String: endpoint]
    }
    static func read(endpoint: String, allowInteraction: Bool = false) throws -> String {
        var request = query(endpoint)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(KeychainAccessPolicy.query(request, allowInteraction: allowInteraction) as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw DictationError.message("Não foi possível ler a chave no Chaves do macOS.")
        }
        return key
    }
    static func save(_ key: String, endpoint: String) throws {
        let request = query(endpoint)
        if key.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw DictationError.message("Não foi possível remover a chave salva.")
            }
            return
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = request.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw DictationError.message("Não foi possível salvar a chave no Chaves do macOS.")
            }
        } else if status != errSecSuccess { throw DictationError.message("Não foi possível atualizar a chave salva.") }
    }
}

@MainActor
final class DictationModel: ObservableObject {
    @Published var settings = DictationSettings()
    @Published var text = ""
    @Published var original = ""
    @Published var history: [DictationRecord] = []
    @Published var apiKey = ""
    @Published var status = "Pronto para ouvir"
    @Published var error: String?
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var elapsed: TimeInterval = 0
    @Published var levels = Array(repeating: CGFloat(0.04), count: 42)
    @Published var shortcutStatus = "⌃ ⇧ Espaço"
    @Published var isEditingShortcut = false
    /// True when recording was started by double tap or by the button: a new press stops it.
    @Published var handsFree = false
    private var keyIsDown = false
    private var pressStartedDictation = false
    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    static let tapLimit: TimeInterval = 0.3
    static let doubleTapWindow: TimeInterval = 0.5
    var checkShortcut: ((DictationShortcut) throws -> Void)?
    var changeShortcut: ((DictationShortcut) throws -> Void)?
    @Published var canRetry = false
    @Published var accessibilityGranted = false
    /// How the last paste went (no dictated text), also saved to `last-paste.txt` for support.
    @Published var pasteDiagnostic = ""
    /// Words recognised so far while you are still speaking (new engine only).
    @Published var liveText = ""
    private var live: (any DictationLiveRecording)?
    private var liveStartedAt = Date()
    private let storage = DictationStorage()
    private let api = DictationAPI()
    private let local = DictationLocalSpeech()
    private let analyzer = DictationEngines.analyzer()
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var audioURL: URL?
    private var activeSettings = DictationSettings()
    private var activeKey = ""
    private let automaticPaste = DictationPaste()
    private var pasteTarget: DictationPasteTarget?
    var isBusy: Bool { isRecording || isProcessing }

    init() {
        do {
            settings = try storage.load(DictationSettings.self, name: "settings.json") ?? DictationSettings()
            history = try storage.load([DictationRecord].self, name: "history.json") ?? []
        } catch { self.error = "Não foi possível carregar os dados anteriores. Os arquivos foram preservados." }
        let migratedKey = "njp.dictationEngineMigrated"
        let migrated = DictationSettings.migratedProvider(
            current: settings.provider, analyzerSupported: DictationProvider.analyzerSupported,
            alreadyMigrated: UserDefaults.standard.bool(forKey: migratedKey))
        if migrated != settings.provider {
            settings.provider = migrated
            saveSettings()
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
        refreshPastePermission()
    }

    func refreshPastePermission() { accessibilityGranted = automaticPaste.hasPermission }
    func allowAutomaticPaste() { automaticPaste.requestPermission(); refreshPastePermission() }

    func persistShortcut(_ shortcut: DictationShortcut) throws {
        var updated = settings
        updated.shortcut = shortcut
        try storage.save(updated, name: "settings.json")
        settings = updated
    }

    func saveSettings() {
        do { try storage.save(settings, name: "settings.json") }
        catch { self.error = "Não foi possível salvar as configurações: \(error.localizedDescription)" }
    }
    func saveKey() {
        do {
            _ = try DictationAPIConnection(endpoint: settings.apiEndpoint, key: apiKey)
            try DictationKeychain.save(apiKey, endpoint: settings.apiEndpoint)
            apiKey = ""
            status = "Chave atualizada no Chaves do macOS"
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func toggle() {
        guard !isEditingShortcut else { return }
        if isRecording { stop() } else if !isProcessing { handsFree = true; start() }
    }
    /// Hold to talk: recording lasts while the shortcut is held. Double tap starts hands-free
    /// recording; the next press stops and pastes.
    func shortcutPressed() {
        guard !isEditingShortcut, !keyIsDown else { return }
        keyIsDown = true
        pressedAt = Date()
        pressStartedDictation = false
        if isRecording { stop(); return }
        guard !isProcessing else { return }
        pressStartedDictation = true
        handsFree = pressedAt.timeIntervalSince(lastTapAt) <= Self.doubleTapWindow
        if handsFree { lastTapAt = .distantPast }
        start()
    }
    func shortcutReleased() {
        guard keyIsDown else { return }
        keyIsDown = false
        guard pressStartedDictation, !handsFree, isBusy else { return }
        if Date().timeIntervalSince(pressedAt) < Self.tapLimit {
            lastTapAt = Date()
            cancel()
            status = "Toque de novo e segure para ditar sem segurar"
        } else if isRecording { stop() }
        // Still preparing the microphone: start() stops as soon as recording begins.
    }
    private func start() {
        isProcessing = true
        error = nil
        status = "Preparando microfone…"
        let token = UUID()
        generation = token
        activeSettings = settings
        refreshPastePermission()
        pasteTarget = settings.autoPaste ? automaticPaste.captureTarget() : nil
        job = Task { [self] in
            do {
                if activeSettings.provider == .analyzer { try await requireAnalyzer().prepare(language: activeSettings.language) }
                else if activeSettings.provider == .apple { try await local.prepare(language: activeSettings.language) }
                else {
                    _ = try DictationAPIConnection(endpoint: activeSettings.endpoint, localOnly: activeSettings.provider == .whisper)
                    activeKey = activeSettings.provider == .api
                        ? (apiKey.isEmpty ? try DictationKeychain.read(endpoint: activeSettings.apiEndpoint) : apiKey) : ""
                    _ = try api.transcriptionRequest(audio: Data(repeating: 0, count: 45), settings: activeSettings, key: activeKey)
                }
                try Task.checkCancellation()
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard generation == token else { return }
                guard allowed else { throw DictationError.message("Autorize o microfone para notchJP em Ajustes do Sistema → Privacidade e Segurança → Microfone.") }
                discardAudio()
                liveText = ""
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ditado-\(UUID().uuidString).wav")
                audioURL = url
                var startedLive = false
                if activeSettings.provider == .analyzer, activeSettings.liveText {
                    do {
                        if let session = try await DictationEngines.live(
                            language: activeSettings.language, vocabulary: activeSettings.vocabulary, fileURL: url,
                            onText: { [weak self] in self?.liveText = $0 },
                            onLevel: { [weak self] in self?.pushLevel(CGFloat($0)) }) {
                            try await session.begin()
                            guard generation == token else { session.cancel(); return }
                            live = session
                            liveStartedAt = Date()
                            startedLive = true
                        }
                    } catch {
                        // Falls back to the plain recorder, which then transcribes the file.
                        live = nil
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                if !startedLive {
                    recorder = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                    ])
                    recorder?.isMeteringEnabled = true
                    guard recorder?.record() == true else { throw DictationError.message("Não foi possível iniciar o microfone.") }
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                elapsed = 0
                isRecording = true
                isProcessing = false
                canRetry = false
                status = handsFree ? "Ouvindo · toque no atalho para parar" : "Ouvindo · solte para colar"
                timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.updateMeter() }
                }
                RunLoop.main.add(timer!, forMode: .common)
                if !keyIsDown && !handsFree { stop() }
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                recorder?.stop()
                recorder = nil
                discardAudio()
                isProcessing = false
                isRecording = false
                self.error = error.localizedDescription
                status = "Confira a conexão"
            }
        }
    }

    private func pushLevel(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(max(0.04, min(1, level)))
    }

    private func updateMeter() {
        if live != nil {
            guard isRecording else { return }
            elapsed = Date().timeIntervalSince(liveStartedAt)
            if elapsed >= 300 { stop() }
            return
        }
        guard isRecording, let recorder else { return }
        guard recorder.isRecording else {
            cancel()
            error = "O microfone foi interrompido. Inicie um novo ditado."
            return
        }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        let level = CGFloat(pow(10, recorder.averagePower(forChannel: 0) / 25))
        levels.removeFirst()
        levels.append(max(0.04, min(1, level)))
        if elapsed >= 300 { stop() }
    }
    func stop() {
        guard isRecording else { return }
        if live != nil { elapsed = Date().timeIntervalSince(liveStartedAt) }
        else { elapsed = recorder?.currentTime ?? elapsed }
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        handsFree = false
        if elapsed < 0.4 {
            live?.cancel()
            live = nil
            discardAudio()
            status = "Ditado muito curto. Tente falar por mais tempo."
            return
        }
        process()
    }
    func retry() { guard canRetry, !isBusy else { return }; process() }

    /// Trims the quiet edges of the saved recording and sends it to the chosen connection.
    private func transcribeFile(_ audioURL: URL, snapshot: DictationSettings, key: String) async throws -> String {
        let preparation = Task.detached(priority: .userInitiated) { try DictationAudioPreparation.prepare(audioURL) }
        let preparedURL = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        defer { if let preparedURL { try? FileManager.default.removeItem(at: preparedURL) } }
        try Task.checkCancellation()
        let transcriptionURL = preparedURL ?? audioURL
        if snapshot.provider == .analyzer {
            return try await requireAnalyzer().transcribe(url: transcriptionURL, language: snapshot.language, vocabulary: snapshot.vocabulary)
        } else if snapshot.provider == .apple {
            return try await local.transcribe(url: transcriptionURL, language: snapshot.language)
        }
        return try await api.transcribe(audio: Data(contentsOf: transcriptionURL), settings: snapshot, key: key)
    }
    private func process() {
        guard let audioURL else { return }
        isProcessing = true
        canRetry = false
        error = nil
        status = "Transcrevendo…"
        let token = generation
        let snapshot = activeSettings
        let key = activeKey
        let duration = elapsed
        let target = pasteTarget
        job = Task {
            do {
                // A live recording already has its text; the saved file is only the fallback and the retry copy.
                var liveRaw: String?
                if let session = live {
                    live = nil
                    liveRaw = try? await session.finish()
                    if liveRaw?.isEmpty == true { liveRaw = nil }
                }
                let raw: String
                if let liveRaw { raw = liveRaw }
                else { raw = try await transcribeFile(audioURL, snapshot: snapshot, key: key) }
                try Task.checkCancellation()
                guard generation == token else { return }
                original = raw
                text = raw
                var output = raw
                try Task.checkCancellation()
                guard generation == token else { return }
                output = DictationTextFormatting.format(output, language: snapshot.language)
                text = output
                copy()
                if snapshot.autoPaste {
                    let result = try await automaticPaste.insert(output, into: target)
                    pasteDiagnostic = automaticPaste.diagnostic.summary
                    try? storage.saveText(pasteDiagnostic, name: "last-paste.txt")
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    status = result.status
                    refreshPastePermission()
                } else { status = "Texto copiado · cole com ⌘ V" }
                if snapshot.keepHistory {
                    history.insert(DictationRecord(original: raw, text: output, provider: snapshot.provider.title, duration: duration), at: 0)
                    history = Array(history.prefix(100))
                    do { try storage.save(history, name: "history.json") }
                    catch { self.error = "Texto copiado, mas o histórico não pôde ser salvo." }
                }
                discardAudio()
                activeKey = ""
                pasteTarget = nil
                isProcessing = false
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                isProcessing = false
                canRetry = true
                self.error = error.localizedDescription
                status = "Não foi possível transcrever · você pode tentar novamente"
            }
        }
    }
    func cancel() {
        generation = UUID()
        job?.cancel()
        local.cancel()
        analyzer?.cancel()
        live?.cancel()
        live = nil
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        isProcessing = false
        handsFree = false
        canRetry = false
        activeKey = ""
        pasteTarget = nil
        discardAudio()
        status = "Ditado cancelado"
    }
    func copy(_ value: String? = nil) {
        let output = value ?? text
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }
    func clearHistory() {
        do { try storage.save([DictationRecord](), name: "history.json"); history = [] }
        catch { self.error = "Não foi possível apagar o histórico." }
    }
    private func requireAnalyzer() throws -> any DictationRecognizing {
        guard let analyzer else {
            throw DictationError.message("O novo reconhecimento exige o macOS 26 ou posterior. Escolha a conexão clássica, Whisper ou API.")
        }
        return analyzer
    }

    private func discardAudio() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }
}
