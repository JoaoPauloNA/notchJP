import CoreAudio
import Synchronization

nonisolated protocol AudioProcessing: AnyObject, Sendable {
    func takePeak() -> Float
    func setGain(_ gain: Float)
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>)
}

nonisolated struct AudioPCMFormat: Equatable {
    let rate: Double
    let channels: Int
    let planar: Bool
    init(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32, (1...2).contains(format.mChannelsPerFrame),
              format.mSampleRate.isFinite, (8000...192000).contains(format.mSampleRate) else {
            throw AudioMixerError(message: "Use uma saída PCM Float32 mono ou estéreo entre 8 e 192 kHz.")
        }
        rate = format.mSampleRate; channels = Int(format.mChannelsPerFrame)
        planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    }
    init(rate: Double, channels: Int, planar: Bool) {
        self.rate = rate; self.channels = channels; self.planar = planar
    }
}

/// Bounded streaming windowed-sinc resampler. All buffers and coefficients are
/// allocated before HAL starts. The audio callback never locks or allocates.
/// The HAL owns read/write/currentGain; UI communication uses atomics only.
nonisolated final class AudioSampleConverter: AudioProcessing, @unchecked Sendable {
    private let inputFormat: AudioPCMFormat
    private let outputFormat: AudioPCMFormat
    private let ratio: Double
    private let capacity = 16384
    private let taps = 32
    private let phases = 256
    private let ring: UnsafeMutablePointer<Float>
    private let coefficients: UnsafeMutablePointer<Float>
    private var written = 16
    private var position = 16.0
    private let target: Atomic<UInt32>
    private let peak = Atomic<UInt32>(0)
    private var currentGain: Float
    private let gainStep: Float

    init(input: AudioPCMFormat, output: AudioPCMFormat, gain: Float) throws {
        guard [input, output].allSatisfy({ $0.rate.isFinite && (8000...192000).contains($0.rate) && (1...2).contains($0.channels) }) else {
            throw AudioMixerError(message: "Formato inválido para conversão de áudio.")
        }
        inputFormat = input; outputFormat = output; ratio = input.rate / output.rate
        let gain = AppAudioDSP.clamp(gain); target = Atomic(gain.bitPattern); currentGain = gain
        gainStep = 1 / Float(max(1, output.rate * 0.01))
        ring = .allocate(capacity: capacity * 2); ring.initialize(repeating: 0, count: capacity * 2)
        coefficients = .allocate(capacity: phases * taps)
        let cutoff = min(1, output.rate / input.rate) * 0.9
        for phase in 0..<phases {
            let fraction = Double(phase) / Double(phases)
            var sum = 0.0
            for tap in 0..<taps {
                let distance = Double(tap - 15) - fraction
                let x = Double.pi * distance * cutoff
                let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
                let window = abs(distance) < 16 ? 0.5 + 0.5 * cos(Double.pi * distance / 16) : 0
                let value = sinc * cutoff * window
                coefficients[phase * taps + tap] = Float(value); sum += value
            }
            for tap in 0..<taps { coefficients[phase * taps + tap] /= Float(sum) }
        }
    }
    deinit { ring.deallocate(); coefficients.deallocate() }
    func setGain(_ gain: Float) { target.store(AppAudioDSP.clamp(gain).bitPattern, ordering: .relaxed) }
    func takePeak() -> Float { Float(bitPattern: peak.exchange(0, ordering: .relaxed)) }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destination = UnsafeMutableAudioBufferListPointer(output)
        for buffer in destination { if let p = buffer.mData { memset(p, 0, Int(buffer.mDataByteSize)) } }
        let inBuffers = inputFormat.planar ? inputFormat.channels : 1
        let outBuffers = outputFormat.planar ? outputFormat.channels : 1
        guard source.count >= inBuffers, destination.count >= outBuffers else { return }
        let offset = source.count - inBuffers // Ignore physical inputs; the app tap is last.
        var inputFrames = Int.max, outputFrames = Int.max
        for i in 0..<inBuffers {
            let b = source[offset + i]; let channels = inputFormat.planar ? 1 : inputFormat.channels
            guard b.mData != nil, b.mNumberChannels == channels else { return }
            inputFrames = min(inputFrames, Int(b.mDataByteSize) / (4 * channels))
        }
        for i in 0..<outBuffers {
            let b = destination[i]; let channels = outputFormat.planar ? 1 : outputFormat.channels
            guard b.mData != nil, b.mNumberChannels == channels else { return }
            outputFrames = min(outputFrames, Int(b.mDataByteSize) / (4 * channels))
        }
        guard inputFrames < capacity - taps else { return }
        if written - Int(position) + inputFrames >= capacity - taps {
            // Bound latency after a discontinuity rather than replaying stale audio.
            position = Double(max(16, written - 16))
        }
        for frame in 0..<inputFrames {
            for channel in 0..<2 {
                let c = min(channel, inputFormat.channels - 1)
                let buffer = source[offset + (inputFormat.planar ? c : 0)]
                let sample = buffer.mData!.assumingMemoryBound(to: Float.self)[frame * (inputFormat.planar ? 1 : inputFormat.channels) + (inputFormat.planar ? 0 : c)]
                ring[((written + frame) % capacity) * 2 + channel] = sample.isFinite ? sample : 0
            }
        }
        written += inputFrames
        let goal = Float(bitPattern: target.load(ordering: .relaxed))
        var blockPeak: Float = 0
        for frame in 0..<outputFrames {
            let center = Int(position)
            guard center + 16 < written else { break }
            let phase = min(phases - 1, Int((position - Double(center)) * Double(phases)))
            var left: Float = 0, right: Float = 0
            for tap in 0..<taps {
                let index = ((center + tap - 15) % capacity) * 2
                let coefficient = coefficients[phase * taps + tap]
                left += ring[index] * coefficient; right += ring[index + 1] * coefficient
            }
            currentGain += min(gainStep, max(-gainStep, goal - currentGain))
            for channel in 0..<outputFormat.channels {
                let sample = (outputFormat.channels == 1 ? (left + right) * 0.5 : (channel == 0 ? left : right)) * currentGain
                let value = sample.isFinite ? sample : 0
                let buffer = destination[outputFormat.planar ? channel : 0]
                buffer.mData!.assumingMemoryBound(to: Float.self)[frame * (outputFormat.planar ? 1 : outputFormat.channels) + (outputFormat.planar ? 0 : channel)] = value
                blockPeak = max(blockPeak, abs(value))
            }
            position += ratio
        }
        // Keep counters bounded during multi-day playback without altering phase.
        if Int(position) > capacity * 4 {
            let shift = (Int(position) / capacity - 1) * capacity
            position -= Double(shift); written -= shift
        }
        peak.store(max(Float(bitPattern: peak.load(ordering: .relaxed)), blockPeak).bitPattern, ordering: .relaxed)
    }
}
