import AVFoundation
import Foundation
import Speech

/// What the model needs from an on-device recognizer.
@MainActor
protocol DictationRecognizing: AnyObject {
    func prepare(language: String) async throws
    func transcribe(url: URL, language: String, vocabulary: [String]) async throws -> String
    func cancel()
}

enum DictationEngines {
    /// nil before macOS 26, where SpeechAnalyzer does not exist.
    @MainActor static func analyzer() -> (any DictationRecognizing)? {
        if #available(macOS 26.0, *) { return DictationAnalyzer() }
        return nil
    }
}

extension DictationProvider {
    static var analyzerSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    /// The best connection this Mac can run without a server.
    static var preferred: DictationProvider { analyzerSupported ? .analyzer : .apple }
    static var selectable: [DictationProvider] { allCases.filter { $0 != .analyzer || analyzerSupported } }
}

/// On-device transcription with the macOS SpeechAnalyzer: better punctuation and accuracy than the
/// classic recognizer, no server to run, and no 1-minute limit. Language assets are managed by the system.
@available(macOS 26.0, *)
@MainActor
final class DictationAnalyzer: DictationRecognizing {
    private var analyzer: SpeechAnalyzer?
    private var generation = UUID()

    /// Checks the language and downloads its model the first time (macOS does the download).
    func prepare(language: String) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw DictationError.message("O novo reconhecimento de fala não está disponível neste Mac. Escolha a conexão clássica, Whisper ou API.")
        }
        let locale = try await resolve(language)
        let transcriber = Self.makeTranscriber(locale)
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            try await request.downloadAndInstall()
        }
    }

    func transcribe(url: URL, language: String, vocabulary: [String]) async throws -> String {
        let locale = try await resolve(language)
        let transcriber = Self.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let token = UUID()
        generation = token
        defer { if generation == token { self.analyzer = nil } }

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: url)
        return try await withTaskCancellationHandler {
            async let collected: String = {
                var text = ""
                for try await result in transcriber.results { text += String(result.text.characters) }
                return text
            }()
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
            let text = try await collected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DictationError.message("Nenhuma fala foi reconhecida.") }
            return text
        } onCancel: {
            Task { @MainActor in await self.analyzer?.cancelAndFinishNow() }
        }
    }

    func cancel() {
        generation = UUID()
        let current = analyzer
        analyzer = nil
        Task { await current?.cancelAndFinishNow() }
    }

    // MARK: Helpers

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    private func resolve(_ language: String) async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) { return match }
        throw DictationError.message("O idioma \(language) não é suportado pelo novo reconhecimento. Escolha outro idioma ou outra conexão.")
    }
}
