import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import IOKit.ps

struct DiskUsage: Equatable {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var availableGB: Int { Int(available / 1_000_000_000) }
    var totalGB: Int { Int(total / 1_000_000_000) }
}

struct BluetoothDevice: Equatable {
    let name: String
    let percent: Int?
}

struct BatteryInfo: Equatable {
    let percent: Int
    let charging: Bool
    let onACPower: Bool
}

/// Disk, memory, CPU and battery of this Mac. Disk and battery refresh in the background;
/// memory and CPU only while the "Mac" page is open.
@MainActor
final class SystemHealthService: ObservableObject {
    static let shared = SystemHealthService()

    /// Free space below this is announced beside the collapsed notch.
    nonisolated static let lowDiskThresholdGB = 25

    @Published private(set) var disk: DiskUsage?
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    /// nil until two samples exist.
    @Published private(set) var cpu: Double?
    @Published private(set) var battery: BatteryInfo?
    /// The busiest process right now, e.g. ("Google Chrome", 24.5).
    @Published private(set) var topProcess: (name: String, cpu: Double)?
    /// Bytes per second, nil until two samples exist.
    @Published private(set) var networkDown: Double?
    @Published private(set) var networkUp: Double?
    @Published private(set) var bluetooth: [BluetoothDevice] = []
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    private var previousNetwork: (rx: UInt64, tx: UInt64, at: Date)?
    private var privacyTimer: Timer?
    private var lastBluetoothRead = Date.distantPast

    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var liveViewCount = 0
    private var liveTimer: Timer?
    private var backgroundTimer: Timer?

    private init() {}

    // MARK: Lifecycle

    func startBackground() {
        guard backgroundTimer == nil else { return }
        refreshSlow()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSlow() }
        }
        refreshPrivacy()
        privacyTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPrivacy() }
        }
    }

    func startLive() {
        liveViewCount += 1
        guard liveTimer == nil else { return }
        refreshLive()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
    }

    func stopLive() {
        liveViewCount = max(0, liveViewCount - 1)
        guard liveViewCount == 0 else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        previousTicks = nil
        previousNetwork = nil
    }

    private func refreshSlow() {
        disk = Self.readDisk()
        battery = Self.readBattery()
    }

    private func refreshLive() {
        refreshSlow()
        memoryUsed = Self.readMemoryUsed()
        if let bytes = Self.readNetworkBytes() {
            let now = Date()
            if let previous = previousNetwork {
                let rate = Self.networkRate(from: previous, to: (bytes.rx, bytes.tx, now))
                networkDown = rate.down
                networkUp = rate.up
            }
            previousNetwork = (bytes.rx, bytes.tx, now)
        }
        if Date().timeIntervalSince(lastBluetoothRead) > 90 {
            lastBluetoothRead = Date()
            Task.detached {
                let devices = Self.readBluetooth()
                await MainActor.run { SystemHealthService.shared.bluetooth = devices }
            }
        }
        Task.detached {
            let top = Self.readTopProcess()
            await MainActor.run { SystemHealthService.shared.topProcess = top }
        }
        if let ticks = Self.readCPUTicks() {
            if let previousTicks {
                cpu = Self.cpuUsage(from: previousTicks, to: ticks)
            }
            previousTicks = ticks
        }
    }

    private func refreshPrivacy() {
        micInUse = Self.readMicInUse()
        cameraInUse = Self.readCameraInUse()
    }

    /// Free GB when the disk is below the threshold, otherwise nil.
    func lowDiskGB() -> Int? {
        Self.lowDiskGB(disk)
    }

    // MARK: Readers

    static func lowDiskGB(_ disk: DiskUsage?, thresholdGB: Int = lowDiskThresholdGB) -> Int? {
        guard let disk, disk.availableGB < thresholdGB else { return nil }
        return disk.availableGB
    }

    static func readDisk() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskUsage(total: Int64(total), available: available)
    }

    /// Busiest process by CPU, skipping this app and the `ps` call itself.
    nonisolated static func readTopProcess() -> (name: String, cpu: Double)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pcpu=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseTopProcess(text, ignoring: ["ps", "notchi"])
    }

    nonisolated static func parseTopProcess(_ output: String, ignoring: Set<String>) -> (name: String, cpu: Double)? {
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let cpu = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            if ignoring.contains(name) { continue }
            return (name, cpu)
        }
        return nil
    }

    // MARK: Network

    nonisolated static func readNetworkBytes() -> (rx: UInt64, tx: UInt64)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            let name = String(cString: interface.pointee.ifa_name)
            if let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               name.hasPrefix("en"), let data = interface.pointee.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(stats.ifi_ibytes)
                tx += UInt64(stats.ifi_obytes)
            }
            cursor = interface.pointee.ifa_next
        }
        return (rx, tx)
    }

    /// Bytes per second between two samples; the 32-bit counters may wrap once.
    nonisolated static func networkRate(from old: (rx: UInt64, tx: UInt64, at: Date),
                                        to new: (rx: UInt64, tx: UInt64, at: Date)) -> (down: Double, up: Double) {
        let seconds = new.at.timeIntervalSince(old.at)
        guard seconds > 0 else { return (0, 0) }
        func delta(_ new: UInt64, _ old: UInt64) -> Double {
            Double(new >= old ? new - old : new + (1 << 32) - old)
        }
        return (delta(new.rx, old.rx) / seconds, delta(new.tx, old.tx) / seconds)
    }

    // MARK: Bluetooth

    nonisolated static func readBluetooth() -> [BluetoothDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBluetooth(data)
    }

    /// Connected devices with their battery, taken from `system_profiler -json`.
    nonisolated static func parseBluetooth(_ data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        func percent(_ value: Any?) -> Int? {
            guard let text = value as? String else { return nil }
            return Int(text.filter(\.isNumber))
        }
        var devices: [BluetoothDevice] = []
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, raw) in entry {
                    guard let attributes = raw as? [String: Any] else { continue }
                    let sides = [percent(attributes["device_batteryLevelLeft"]), percent(attributes["device_batteryLevelRight"])].compactMap { $0 }
                    let level = percent(attributes["device_batteryLevelMain"]) ?? sides.min() ?? percent(attributes["device_batteryLevelCase"])
                    devices.append(BluetoothDevice(name: name, percent: level))
                }
            }
        }
        return devices.sorted { ($0.percent != nil ? 0 : 1, $0.name) < ($1.percent != nil ? 0 : 1, $1.name) }
    }

    // MARK: Microphone and camera

    nonisolated static func readMicInUse() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    nonisolated static func readCameraInUse() -> Bool {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
            .devices.contains { $0.isInUseByAnotherApplication }
    }

    static func readMemoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * page
    }

    static func readCPUTicks() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3)
    }

    static func cpuUsage(from old: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32),
                         to new: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)) -> Double {
        let user = Double(new.user &- old.user)
        let system = Double(new.system &- old.system)
        let idle = Double(new.idle &- old.idle)
        let nice = Double(new.nice &- old.nice)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total : 0
    }

    static func readBattery() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            return BatteryInfo(
                percent: maximum > 0 ? current * 100 / maximum : current,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onACPower: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            )
        }
        return nil
    }
}
