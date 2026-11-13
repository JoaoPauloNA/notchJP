import AppKit
import CoreAudio

struct AudioMixerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AudioMixerHardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw AudioMixerError(message: "\(action) (Core Audio: \(status)). Verifique a permissão de gravação de áudio do sistema nos Ajustes do macOS.")
        }
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var property = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }, "Não foi possível consultar o áudio")
        return value
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Não foi possível listar o áudio")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }, "Não foi possível listar o áudio")
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let value: CFString = try self.value(object, selector, initial: "" as CFString)
        return value as String
    }

    static func defaultOutput() throws -> AudioObjectID {
        let device = try value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        guard device != 0 else { throw AudioMixerError(message: "Conecte uma saída de áudio ao Mac.") }
        return device
    }
}

/// One private duplex aggregate per app. It never becomes the system output device.
/// `.mutedWhenTapped` restores the app's original path as soon as this IO stops.
@MainActor final class AppAudioRoute {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var dsp: AppAudioDSP?
    let processes: [AudioObjectID]
    let output: AudioObjectID
    let source: AudioObjectID
    func takePeak() -> Float { dsp?.takePeak() ?? 0 }

    init(processes: [AudioObjectID], output: AudioObjectID, source: AudioObjectID? = nil, gain: Float) throws {
        self.processes = processes
        self.output = output
        self.source = source ?? output
        do { try start(gain: gain) } catch { stop(); throw error }
    }

    func setGain(_ gain: Float) { dsp?.setGain(gain) }

    private func start(gain: Float) throws {
        guard !processes.isEmpty else { throw AudioMixerError(message: "O aplicativo ainda não abriu uma saída de áudio.") }
        let uid = try AudioMixerHardware.string(output, kAudioDevicePropertyDeviceUID)
        let streams = try AudioMixerHardware.objects(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard streams.count == 1 else {
            throw AudioMixerError(message: "Esta saída tem vários fluxos. Escolha os alto-falantes do Mac ou uma saída estéreo.")
        }
        // A device-specific tap avoids the attenuation of stereo mixdown on multichannel devices.
        let sourceUID = try AudioMixerHardware.string(source, kAudioDevicePropertyDeviceUID)
        let description = CATapDescription(processes: processes, deviceUID: sourceUID, stream: 0)
        description.name = "notchJP · volume por app"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try AudioMixerHardware.check(AudioHardwareCreateProcessTap(description, &tap), "Não foi possível controlar este aplicativo")
        let format = try AudioMixerHardware.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, (1...2).contains(format.mChannelsPerFrame),
              format.mSampleRate > 0 else {
            throw AudioMixerError(message: "Esta saída não oferece áudio mono/estéreo compatível com o mixer.")
        }
        let destination = try AudioMixerHardware.value(streams[0], kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        guard destination.mSampleRate == format.mSampleRate,
              destination.mChannelsPerFrame == format.mChannelsPerFrame,
              destination.mFormatID == format.mFormatID,
              destination.mFormatFlags == format.mFormatFlags,
              destination.mBitsPerChannel == format.mBitsPerChannel else {
            throw AudioMixerError(message: "A saída escolhida tem um formato diferente da origem. Use saídas com a mesma frequência e canais; conversão ainda não disponível.")
        }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapUID = try AudioMixerHardware.string(tap, kAudioTapPropertyUID)
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "notchJP · mixer",
            kAudioAggregateDeviceUIDKey: "notchjp.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        try AudioMixerHardware.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "Não foi possível preparar o mixer")
        let processor = AppAudioDSP(gain: gain, channels: Int(format.mChannelsPerFrame), planar: planar, sampleRate: format.mSampleRate)
        dsp = processor
        try AudioMixerHardware.check(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { _, input, _, output, _ in
            processor.render(input: input, output: output)
        }, "Não foi possível preparar a reprodução")
        try disablePhysicalInputs()
        try AudioMixerHardware.check(AudioDeviceStart(device, io), "Não foi possível iniciar o mixer")
    }

    private func disablePhysicalInputs() throws {
        // Explicitly disable microphone/input streams of the physical subdevice.
        let count = try AudioMixerHardware.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        guard count > 0, let io else { throw AudioMixerError(message: "O mixer não encontrou o áudio do aplicativo.") }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (count - 1) * MemoryLayout<UInt32>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = memory.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(io, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let flags = memory.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
        flags[count - 1] = 1
        var property = AudioMixerHardware.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        try AudioMixerHardware.check(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(size), memory), "Não foi possível isolar o áudio do aplicativo")
    }

    func stop() {
        if let io {
            AudioDeviceStop(device, io)
            AudioDeviceDestroyIOProcID(device, io)
        }
        io = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device) }
        device = 0
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        tap = 0
        dsp = nil
    }
}
