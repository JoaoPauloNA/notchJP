import Darwin
import Foundation

nonisolated struct AntigravityUsageSnapshot: Sendable {
    var argonWeekly: QuotaPeriod?
    var geminiSession: QuotaPeriod?
    var geminiWeekly: QuotaPeriod?

    static func parse(_ data: Data, now: Date) throws -> Self {
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "SUCCESS",
              let command = object["command"] as? [String: Any], command["name"] as? String == "usage",
              let body = command["data"] as? [String: Any],
              let groups = body["groups"] as? [[String: Any]], groups.count <= 12 else {
            throw AntigravityUsageError.invalidResponse
        }
        var snapshot = Self()
        var seen = Set<String>()
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]], buckets.count <= 12 else {
                throw AntigravityUsageError.invalidResponse
            }
            for bucket in buckets {
                guard let id = bucket["id"] as? String else { continue }
                let expectedWindow: String
                switch id {
                case "gemini-argon-wtu-weekly", "gemini-weekly": expectedWindow = "weekly"
                case "gemini-5h": expectedWindow = "5h"
                default: continue
                }
                guard seen.insert(id).inserted,
                      bucket["window"] as? String == expectedWindow,
                      let fraction = bucket["remaining_fraction"] as? NSNumber,
                      CFGetTypeID(fraction) != CFBooleanGetTypeID(),
                      fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue),
                      let reset = bucket["reset_time"] as? String else {
                    throw AntigravityUsageError.invalidResponse
                }
                let period = QuotaPeriod(utilization: (1 - fraction.doubleValue) * 100, resetsAt: reset)
                guard let resetDate = period.resetDate else { throw AntigravityUsageError.invalidResponse }
                guard resetDate > now else { continue }
                switch id {
                case "gemini-argon-wtu-weekly": snapshot.argonWeekly = period
                case "gemini-5h": snapshot.geminiSession = period
                case "gemini-weekly": snapshot.geminiWeekly = period
                default: break
                }
            }
        }
        return snapshot
    }

    mutating func discardExpired(at now: Date) {
        if (argonWeekly?.resetDate ?? .distantPast) <= now { argonWeekly = nil }
        if (geminiSession?.resetDate ?? .distantPast) <= now { geminiSession = nil }
        if (geminiWeekly?.resetDate ?? .distantPast) <= now { geminiWeekly = nil }
    }
}

nonisolated enum AntigravityUsageError: Error, LocalizedError, Equatable {
    case notInstalled, timedOut, invalidResponse, commandFailed

    var errorDescription: String? {
        switch self {
        case .notInstalled: "AGY não encontrado neste Mac"
        case .timedOut: "AGY demorou para responder; tentando novamente"
        case .invalidResponse: "AGY não retornou cotas válidas"
        case .commandFailed: "Abra o AGY e confira o login; tentando novamente"
        }
    }
}

nonisolated enum AntigravityUsageCommand {
    // /usage is an official read-only slash command, not a model prompt.
    static let arguments = ["--log-file", "/dev/null", "--print", "/usage",
                            "--output-format", "json", "--print-timeout", "20s"]

    static func capture(executable: URL? = nil, timeout: TimeInterval = 25) throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .filter { $0.hasPrefix("/") }.map { "\($0)/agy" }
        guard let executable = executable ?? paths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map({ URL(fileURLWithPath: $0) }) else { throw AntigravityUsageError.notInstalled }

        let process = Process(), output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw AntigravityUsageError.commandFailed }
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var result = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AntigravityUsageError.timedOut }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                guard result.count + count <= 1_048_576 else { throw AntigravityUsageError.invalidResponse }
                result.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count < 0 && errno != EAGAIN && errno != EINTR { throw AntigravityUsageError.commandFailed }
            if !process.isRunning {
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AntigravityUsageError.commandFailed }
                return result
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
    }
}

@MainActor @Observable
final class AntigravityUsageService {
    static let shared = AntigravityUsageService()

    private(set) var snapshot = AntigravityUsageSnapshot()
    private(set) var isUsageStale = false
    private(set) var status = "Consultando AGY..."
    private var timer: Timer?
    private(set) var isRefreshing = false
    private var generation: UInt64 = 0
    private let fetch: @Sendable () async throws -> Data
    private let now: () -> Date

    init(fetch: @escaping @Sendable () async throws -> Data = {
        try await Task.detached(priority: .utility) { try AntigravityUsageCommand.capture() }.value
    }, now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        generation &+= 1
        isRefreshing = false
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let requestGeneration = generation
        defer { if generation == requestGeneration { isRefreshing = false } }
        do {
            let data = try await fetch()
            guard generation == requestGeneration else { return }
            snapshot = try AntigravityUsageSnapshot.parse(data, now: now())
            isUsageStale = false
            status = "Cota não informada pelo AGY"
        } catch {
            guard generation == requestGeneration else { return }
            snapshot.discardExpired(at: now())
            isUsageStale = snapshot.argonWeekly != nil || snapshot.geminiSession != nil || snapshot.geminiWeekly != nil
            status = error.localizedDescription
        }
    }
}
