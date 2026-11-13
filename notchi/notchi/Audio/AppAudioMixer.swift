import AppKit
import Combine
import CoreAudio

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID] = []
    var isPlaying = false
}

nonisolated struct AudioAppLevel: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    var gain: Float { muted ? 0 : AppAudioDSP.clamp(volume) }
}

@MainActor final class AppAudioMixer: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    static let shared = AppAudioMixer()
    private static let levelsKey = "njp.audioMixer.levels"
    private static let enabledKey = "njp.audioMixer.enabled"
    @Published private(set) var outputs: [AudioOutputChoice] = []
    @Published private(set) var destinations: [String: String] = [:]
    func destination(for id: String) -> String { destinations[id] ?? "" }
    func setDestination(_ uid: String, for id: String) {
        destinations[id] = uid
        defaults.set(destinations, forKey: "njp.audioMixer.destinations")
        routes.removeValue(forKey: id)?.stop()
        errors[id] = nil
        refresh()
    }
    func takePeak(_ id: String) -> Float { routes[id]?.takePeak() ?? 0 }
    private func target(for id: String, fallback: AudioObjectID) -> AudioObjectID? {
        let uid = destination(for: id)
        return uid.isEmpty ? fallback : outputs.first(where: { $0.uid == uid })?.device
    }
    private func needsRoute(_ app: AudioApp) -> Bool {
        level(for: app.id).gain < 1 || !destination(for: app.id).isEmpty || (visible && app.isPlaying)
    }
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var enabled = false
    @Published private(set) var levels: [String: AudioAppLevel] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var outputName = "Saída padrão do Mac"
    @Published private(set) var status: String?
    private var routes: [String: AppAudioRoute] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var visible = false
    private var sleeping = false
    private var outputSignature = ""
    private var currentOutput: AudioObjectID?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destinations = defaults.dictionary(forKey: "njp.audioMixer.destinations") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: Self.levelsKey),
           let saved = try? JSONDecoder().decode([String: AudioAppLevel].self, from: data) {
            levels = saved.mapValues { AudioAppLevel(volume: AppAudioDSP.clamp($0.volume), muted: $0.muted) }
        }
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    // Called during app launch, even when the audio panel is closed.
    func start() { setEnabled(defaults.bool(forKey: Self.enabledKey)) }

    func show() { visible = true; refresh(); updateTimer() }
    func hide() { visible = false; refresh(); updateTimer() }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        errors.removeAll()
        if enabled {
            observeSleep()
            refresh()
        } else {
            releaseRoutes()
        }
        updateTimer()
    }

    func level(for id: String) -> AudioAppLevel { levels[id] ?? AudioAppLevel() }

    func setVolume(_ volume: Float, for id: String) {
        var level = level(for: id)
        level.volume = AppAudioDSP.clamp(volume)
        // Dragging up from mute restores sound at the requested level.
        level.muted = false
        setLevel(level, for: id)
    }

    func toggleMute(_ id: String) {
        var level = level(for: id)
        if level.gain == 0 {
            level.muted = false
            if level.volume == 0 { level.volume = 1 }
        } else {
            level.muted = true
        }
        setLevel(level, for: id)
    }

    private func setLevel(_ level: AudioAppLevel, for id: String) {
        levels[id] = level
        persist()
        errors[id] = nil
        // Slider events must not enumerate every process or rebuild an existing route.
        if let output = currentOutput, let app = apps.first(where: { $0.id == id }) {
            applyLevel(to: app, output: output)
        }
    }

    func retry(_ id: String) { errors[id] = nil; refresh() }

    func restoreAll() {
        releaseRoutes()
        levels.removeAll()
        destinations.removeAll()
        defaults.removeObject(forKey: "njp.audioMixer.destinations")
        errors.removeAll()
        defaults.removeObject(forKey: Self.levelsKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(levels) { defaults.set(data, forKey: Self.levelsKey) }
    }

    func isControlled(_ id: String) -> Bool { routes[id] != nil }

    func refresh() {
        guard !sleeping else { return }
        do {
            apps = try discoverApps()
            outputs = try AudioMixerHardware.objects(AudioMixerHardware.system, kAudioHardwarePropertyDevices).compactMap { device in
                guard let streams = try? AudioMixerHardware.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), !streams.isEmpty,
                      let uid = try? AudioMixerHardware.string(device, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("notchjp.mixer.") else { return nil }
                return AudioOutputChoice(device: device, uid: uid, name: (try? AudioMixerHardware.string(device, kAudioObjectPropertyName)) ?? uid)
            }
            let output = try AudioMixerHardware.defaultOutput()
            currentOutput = output
            outputName = (try? AudioMixerHardware.string(output, kAudioObjectPropertyName)) ?? "Saída padrão do Mac"
            let rate = try AudioMixerHardware.value(output, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
            let streams = try AudioMixerHardware.objects(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            let formats = try streams.map { stream in
                let format = try AudioMixerHardware.value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
                return "\(stream):\(format.mSampleRate):\(format.mChannelsPerFrame):\(format.mFormatFlags)"
            }
            let signature = "\(output):\(rate):\(formats)"
            if outputSignature != signature {
                releaseRoutes()
                errors.removeAll()
                outputSignature = signature
            }
            status = nil
            let current = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
            for id in Array(routes.keys) {
                guard let app = current[id], let route = routes[id],
                      route.processes == app.processes, route.output == (target(for: id, fallback: output) ?? output), route.source == output,
                      enabled, needsRoute(app) else {
                    routes.removeValue(forKey: id)?.stop()
                    continue
                }
                route.setGain(target(for: id, fallback: output) == nil ? 0 : level(for: id).gain)
            }
            guard enabled else { return }
            for app in apps { applyLevel(to: app, output: output) }
        } catch {
            releaseRoutes()
            currentOutput = nil
            status = error.localizedDescription
        }
    }

    private func applyLevel(to app: AudioApp, output: AudioObjectID) {
        let unavailable = target(for: app.id, fallback: output) == nil
        let gain: Float = unavailable ? 0 : level(for: app.id).gain
        guard enabled, !sleeping, needsRoute(app) else {
            routes.removeValue(forKey: app.id)?.stop()
            return
        }
        let destination = target(for: app.id, fallback: output) ?? output
        let unavailableMessage = "Saída indisponível. Som suspenso até reconectar o dispositivo ou escolher outra saída."
        if unavailable { errors[app.id] = unavailableMessage }
        else if errors[app.id] == unavailableMessage { errors[app.id] = nil }
        if let route = routes[app.id] { route.setGain(gain); return }
        guard !app.processes.isEmpty, (errors[app.id] == nil || unavailable) else { return }
        do {
            routes[app.id] = try AppAudioRoute(processes: app.processes, output: destination, source: output, gain: gain)
        } catch {
            // A failed route has already destroyed its tap; original sound is restored.
            errors[app.id] = error.localizedDescription
        }
    }

    private func discoverApps() throws -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications
        var groups: [String: AudioApp] = [:]
        let ownID = Bundle.main.bundleIdentifier
        for app in running where app.activationPolicy == .regular && app.bundleIdentifier != ownID {
            guard let id = app.bundleIdentifier else { continue }
            groups[id] = AudioApp(id: id, name: app.localizedName ?? id, icon: app.icon)
        }
        let processes = try AudioMixerHardware.objects(AudioMixerHardware.system, kAudioHardwarePropertyProcessObjectList)
        for process in processes {
            guard let pid = try? AudioMixerHardware.value(process, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = (try? AudioMixerHardware.string(process, kAudioProcessPropertyBundleID)) ?? app?.bundleIdentifier ?? ""
            // Chromium/Electron can put audio in a helper nested in the main .app.
            let owner = Self.ownerID(bundleID: bundleID, bundlePath: app?.bundleURL?.path,
                                     candidates: running.compactMap { item in
                guard let id = item.bundleIdentifier, item.activationPolicy == .regular else { return nil }
                return (id: id, path: item.bundleURL?.path ?? "")
            })
            guard owner != ownID else { continue }
            let id = owner.isEmpty ? "process:\(pid)" : owner
            let playing = (try? AudioMixerHardware.value(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
            // Hide background services that have never opened an output.
            guard groups[id] != nil || playing || routes[id] != nil else { continue }
            if groups[id] == nil { groups[id] = AudioApp(id: id, name: app?.localizedName ?? bundleID, icon: app?.icon) }
            var group = groups[id]!
            group.processes.append(process)
            group.isPlaying = group.isPlaying || playing
            groups[id] = group
        }
        return groups.values.map { app in
            var copy = app
            copy.processes.sort()
            return copy
        }.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated static func ownerID(bundleID: String, bundlePath: String?, candidates: [(id: String, path: String)]) -> String {
        if let exact = candidates.first(where: { $0.id == bundleID }) { return exact.id }
        if let bundlePath, let owner = candidates.filter({ !$0.path.isEmpty && bundlePath.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) { return owner.id }
        // Boundary prevents e.g. com.example.PlayerTwo from matching com.example.Player.
        return candidates.filter { bundleID.hasPrefix($0.id + ".") }
            .max(by: { $0.id.count < $1.id.count })?.id ?? bundleID
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard visible || enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: visible ? 2 : 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = visible ? 0.2 : 1
    }

    private func observeSleep() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.releaseRoutes() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.refresh() }
        })
    }

    private func releaseRoutes() {
        for route in routes.values { route.stop() }
        routes.removeAll()
    }

    func stop() {
        // Release live audio without changing the user's saved activation choice.
        enabled = false
        releaseRoutes()
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}

struct AudioOutputChoice: Identifiable {
    var id: String { uid }
    let device: AudioObjectID
    let uid: String
    let name: String
}
