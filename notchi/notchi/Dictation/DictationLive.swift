import AVFoundation
import Foundation
import Speech

/// AVAudioPCMBuffer is not Sendable; the audio thread hands it over once and never touches it again.
struct DictationSendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Where audio comes from: the microphone, or a file in tests.
protocol DictationAudioSource: AnyObject, Sendable {
    func start(deliver: @escaping @Sendable (DictationSendableBuffer) -> Void) throws
    func stop()
}

/// Microphone through AVAudioEngine.
final class DictationMicSource: DictationAudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(deliver: @escaping @Sendable (DictationSendableBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.message("Não foi possível iniciar o microfone.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            deliver(DictationSendableBuffer(buffer: buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// A WAV file played into the pipeline in real-time-ish chunks (tests and the self-check).
final class DictationFileSource: DictationAudioSource, @unchecked Sendable {
    private let url: URL
    private let chunkInterval: Duration
    private var task: Task<Void, Never>?

    init(url: URL, chunkInterval: Duration = .milliseconds(60)) {
        self.url = url
        self.chunkInterval = chunkInterval
    }

    func start(deliver: @escaping @Sendable (DictationSendableBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let interval = chunkInterval
        task = Task.detached {
            while !Task.isCancelled, file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else { return }
                do { try file.read(into: buffer, frameCount: 2048) } catch { return }
                deliver(DictationSendableBuffer(buffer: buffer))
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() { task?.cancel() }
}

/// What the model needs from a live (streaming) recording.
@MainActor
protocol DictationLiveRecording: AnyObject {
    func begin() async throws
    /// Stops the microphone and returns the final text.
    func finish() async throws -> String
    func cancel()
}

extension DictationEngines {
    /// nil before macOS 26.
    @MainActor
    static func live(language: String, vocabulary: [String], fileURL: URL,
                     source: (any DictationAudioSource)? = nil,
                     onText: @escaping @MainActor (String) -> Void,
                     onLevel: @escaping @MainActor (Float) -> Void) async throws -> (any DictationLiveRecording)? {
        if #available(macOS 26.0, *) {
            return try await DictationLiveSession(language: language, vocabulary: vocabulary, fileURL: fileURL,
                                                  source: source ?? DictationMicSource(), onText: onText, onLevel: onLevel)
        }
        return nil
    }
}

/// Does the audio-thread work: level, conversion to the analyzer's format, copy to disk and hand-off.
@available(macOS 26.0, *)
private final class DictationLivePipeline: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var writer: AVAudioFile?
    private let level: @Sendable (Float) -> Void

    init(converter: AVAudioConverter, target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         writer: AVAudioFile?, level: @escaping @Sendable (Float) -> Void) {
        self.converter = converter
        self.target = target
        self.continuation = continuation
        self.writer = writer
        self.level = level
    }

    func process(_ wrapped: DictationSendableBuffer) {
        let input = wrapped.buffer
        level(Self.level(of: input))
        let ratio = target.sampleRate / input.format.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 64) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return }
        try? writer?.write(from: output)
        continuation.yield(AnalyzerInput(buffer: output))
    }

    func closeFile() { writer = nil }

    /// 0...1 in the same range the old recorder meter used.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0.04 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0.04, min(1, powf(10, decibels / 25)))
    }
}

@available(macOS 26.0, *)
@MainActor
final class DictationLiveSession: DictationLiveRecording {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let source: any DictationAudioSource
    private let fileURL: URL
    private let vocabulary: [String]
    private let onText: @MainActor (String) -> Void
    private let onLevel: @MainActor (Float) -> Void
    private var pipeline: LazyPipeline?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, Error>?

    init(language: String, vocabulary: [String], fileURL: URL, source: any DictationAudioSource,
         onText: @escaping @MainActor (String) -> Void, onLevel: @escaping @MainActor (Float) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw DictationError.message("O idioma \(language) não é suportado pelo novo reconhecimento.")
        }
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.source = source
        self.fileURL = fileURL
        self.vocabulary = vocabulary
        self.onText = onText
        self.onLevel = onLevel
    }

    func begin() async throws {
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.message("O reconhecimento não informou um formato de áudio.")
        }
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await analyzer.start(inputSequence: stream)

        let onLevel = self.onLevel
        let pipeline = LazyPipeline(target: target, continuation: continuation, fileURL: fileURL) { value in
            Task { @MainActor in onLevel(value) }
        }
        self.pipeline = pipeline
        try source.start { buffer in
            pipeline.deliver(buffer)
        }

        let transcriber = self.transcriber
        let onText = self.onText
        results = Task {
            var finalText = ""
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal { finalText += text; volatile = "" } else { volatile = text }
                let shown = finalText + volatile
                await MainActor.run { onText(shown) }
            }
            return finalText
        }
    }

    func finish() async throws -> String {
        source.stop()
        pipeline?.finish()
        continuation?.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { await analyzer.cancelAndFinishNow(); throw error }
        let text = try await results?.value ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        source.stop()
        pipeline?.finish()
        continuation?.finish()
        results?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Creates the real pipeline on the first buffer, when the input format is known.
@available(macOS 26.0, *)
private final class LazyPipeline: @unchecked Sendable {
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let fileURL: URL
    private let level: @Sendable (Float) -> Void
    private var inner: DictationLivePipeline?

    fileprivate init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, fileURL: URL,
                     level: @escaping @Sendable (Float) -> Void) {
        self.target = target
        self.continuation = continuation
        self.fileURL = fileURL
        self.level = level
    }

    func deliver(_ wrapped: DictationSendableBuffer) {
        if inner == nil {
            guard let converter = AVAudioConverter(from: wrapped.buffer.format, to: target) else { return }
            let writer = try? AVAudioFile(
                forWriting: fileURL,
                settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: target.sampleRate,
                           AVNumberOfChannelsKey: target.channelCount, AVLinearPCMBitDepthKey: 16,
                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                commonFormat: target.commonFormat, interleaved: target.isInterleaved)
            inner = DictationLivePipeline(converter: converter, target: target, continuation: continuation, writer: writer, level: level)
        }
        inner?.process(wrapped)
    }

    func finish() { inner?.closeFile() }
}
