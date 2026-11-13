import AppKit
import Combine
import Foundation

/// Focus / pomodoro timer. The notch shows the countdown beside the camera while it runs.
@MainActor
final class FocusTimerService: ObservableObject {
    static let shared = FocusTimerService()

    enum State: Equatable {
        case idle
        case running(end: Date, total: TimeInterval)
        case paused(remaining: TimeInterval, total: TimeInterval)
        case finished(at: Date)
    }

    /// How long "fim" is announced after the timer ends.
    static let finishedWindow: TimeInterval = 60

    @Published private(set) var state: State = .idle
    private var timer: Timer?

    private init() {}

    func start(minutes: Int, now: Date = Date()) {
        let total = TimeInterval(max(1, minutes) * 60)
        state = .running(end: now.addingTimeInterval(total), total: total)
        schedule()
    }

    func pause(now: Date = Date()) {
        guard case .running(let end, let total) = state else { return }
        state = .paused(remaining: max(0, end.timeIntervalSince(now)), total: total)
        timer?.invalidate()
    }

    func resume(now: Date = Date()) {
        guard case .paused(let remaining, let total) = state else { return }
        state = .running(end: now.addingTimeInterval(remaining), total: total)
        schedule()
    }

    func reset() {
        timer?.invalidate()
        state = .idle
    }

    func remaining(now: Date = Date()) -> TimeInterval {
        switch state {
        case .running(let end, _): max(0, end.timeIntervalSince(now))
        case .paused(let remaining, _): remaining
        case .idle, .finished: 0
        }
    }

    func progress(now: Date = Date()) -> Double {
        switch state {
        case .running(_, let total), .paused(_, let total):
            total > 0 ? 1 - remaining(now: now) / total : 0
        case .finished: 1
        case .idle: 0
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick(now: Date = Date()) {
        guard case .running(let end, _) = state, now >= end else { return }
        timer?.invalidate()
        state = .finished(at: end)
        NSSound(named: "Glass")?.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.finishedWindow + 1))
            self.objectWillChange.send()
        }
    }

    /// "24:05", "1:00:00".
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
    }
}
