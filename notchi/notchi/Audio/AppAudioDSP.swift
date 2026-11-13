import CoreAudio
import Synchronization

/// The HAL callback owns `currentGain`; the UI only writes the atomic target.
/// No locks, allocation, file access or dispatch from the audio thread.
nonisolated final class AppAudioDSP: @unchecked Sendable {
    private let peak = Atomic<UInt32>(0)
    func takePeak() -> Float { Float(bitPattern: peak.exchange(0, ordering: .relaxed)) }
    private let target: Atomic<UInt32>
    private var currentGain: Float
    private let channels: Int
    private let planar: Bool
    private let rampFrames: Float

    init(gain: Float, channels: Int, planar: Bool, sampleRate: Double) {
        let safe = Self.clamp(gain)
        target = Atomic(safe.bitPattern)
        currentGain = safe
        self.channels = channels
        self.planar = planar
        rampFrames = Float(max(1, sampleRate * 0.01))
    }

    static func clamp(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 1 }

    func setGain(_ value: Float) { target.store(Self.clamp(value).bitPattern, ordering: .relaxed) }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destination = UnsafeMutableAudioBufferListPointer(output)
        // The physical device's input streams are disabled. The tap is appended last.
        let bufferCount = planar ? channels : 1
        for buffer in destination {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard source.count >= bufferCount, destination.count >= bufferCount else { return }
        let offset = source.count - bufferCount
        let samplesPerFrame = planar ? 1 : channels
        var frames = Int.max
        for index in 0..<bufferCount {
            let from = source[offset + index]
            let to = destination[index]
            guard from.mData != nil, to.mData != nil,
                  from.mNumberChannels == samplesPerFrame, to.mNumberChannels == samplesPerFrame else { return }
            frames = min(frames, Int(min(from.mDataByteSize, to.mDataByteSize)) / MemoryLayout<Float>.size / samplesPerFrame)
        }
        let goal = Float(bitPattern: target.load(ordering: .relaxed))
        let step: Float = 1 / rampFrames
        var blockPeak: Float = 0
        for frame in 0..<frames {
            currentGain += min(step, max(-step, goal - currentGain))
            for index in 0..<bufferCount {
                let from = source[offset + index].mData!.assumingMemoryBound(to: Float.self)
                let to = destination[index].mData!.assumingMemoryBound(to: Float.self)
                for channel in 0..<samplesPerFrame {
                    let sample = frame * samplesPerFrame + channel
                    to[sample] = from[sample] * currentGain
                    if to[sample].isFinite { blockPeak = max(blockPeak, abs(to[sample])) }
                }
            }
        }
        let previous = Float(bitPattern: peak.load(ordering: .relaxed))
        peak.store(max(previous, blockPeak).bitPattern, ordering: .relaxed)
    }
}
