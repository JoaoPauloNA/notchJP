// Ported from BlabberType (MIT, by the same author).
import Foundation
import AVFoundation

/// Trim only the quiet edges; retain pauses and a generous margin around speech.
nonisolated enum DictationAudioPreparation {
    static func retainedFrames(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Range<Int>? {
        let threshold: Float = 0.0003 // About -70 dBFS: keep even very quiet speech.
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return nil }
        let margin = Int(sampleRate * 0.3)
        return max(0, first - margin)..<min(samples.count, last + margin + 1)
    }

    /// Returns a separate temporary file, leaving the original available for retry.
    static func prepare(_ url: URL) throws -> URL? {
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        // The recorder produces mono PCM. Preserve any unexpected format verbatim.
        guard format.channelCount == 1, format.commonFormat == .pcmFormatFloat32,
              input.length > 0, input.length <= 16_000 * 301,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else { return nil }
        try input.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        let values = UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
        guard let range = retainedFrames(values, sampleRate: format.sampleRate) else {
            // Don't classify quiet recordings as silence: only reject digital zero.
            if values.allSatisfy({ $0 == 0 }) {
                throw DictationError.message("O áudio está silencioso. Confira o microfone e tente novamente.")
            }
            return nil
        }
        // Avoid rewriting files for negligible savings (less than half a second).
        guard values.count - range.count >= Int(format.sampleRate * 0.5) else { return nil }
        try Task.checkCancellation()
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let destination = trimmed.floatChannelData?[0] else { return nil }
        trimmed.frameLength = AVAudioFrameCount(range.count)
        destination.update(from: samples.advanced(by: range.lowerBound), count: range.count)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("notchjp-trimmed-\(UUID().uuidString).wav")
        do {
            // Create privately before AVAudioFile opens the output.
            guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw DictationError.message("Não foi possível preparar o áudio temporário.")
            }
            let writer = try AVAudioFile(forWriting: output, settings: input.fileFormat.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: trimmed)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
