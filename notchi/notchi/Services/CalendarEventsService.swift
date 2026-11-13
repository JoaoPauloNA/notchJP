import Combine
import EventKit
import SwiftUI

struct CalendarEventItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let joinURL: URL?
    var location: String? = nil
    var notes: String? = nil
    var calendarName: String = ""

    /// "6 de nov. · 09:30 – 09:45", "6 de nov. · Dia todo" or a span across days.
    func timeRangeText(locale: Locale = Locale(identifier: "pt_BR"), calendar: Calendar = .current) -> String {
        let day = start.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        if isAllDay { return "\(day) · Dia todo" }
        let from = start.formatted(.dateTime.hour().minute().locale(locale))
        let to = end.formatted(.dateTime.hour().minute().locale(locale))
        if calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) { return "\(day) · \(from) – \(to)" }
        let endDay = end.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return "\(day) \(from) – \(endDay) \(to)"
    }

    /// Notes cut to a size that fits the popover, without link noise.
    var shortNotes: String? {
        guard let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > 220 ? String(text.prefix(220)) + "…" : text
    }
}

/// Reads events from the Mac's own Calendar (EventKit), so no account or key is needed.
@MainActor
final class CalendarEventsService: ObservableObject {
    static let shared = CalendarEventsService()

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var monthEvents: [CalendarEventItem] = []
    @Published private(set) var upcoming: [CalendarEventItem] = []

    private let store = EKEventStore()
    private var visibleMonth = Date()
    private var observer: NSObjectProtocol?

    private init() {
        updateAccess()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Access

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        case .notDetermined: access = .unknown
        @unknown default: access = .unknown
        }
    }

    /// Asks macOS for permission; only called when the user taps "Conectar agenda".
    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        updateAccess()
        refresh()
    }

    // MARK: Loading

    func setVisibleMonth(_ month: Date) {
        visibleMonth = month
        refresh()
    }

    func refresh(now: Date = Date()) {
        updateAccess()
        guard access == .granted else {
            monthEvents = []
            upcoming = []
            return
        }
        let calendar = Calendar.current
        if let interval = calendar.dateInterval(of: .month, for: visibleMonth) {
            monthEvents = fetch(from: interval.start, to: interval.end)
        }
        upcoming = fetch(from: now, to: now.addingTimeInterval(36 * 3600))
    }

    private func fetch(from start: Date, to end: Date) -> [CalendarEventItem] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEventItem(
                    id: (event.eventIdentifier ?? UUID().uuidString) + "\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Sem título",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: Color(cgColor: event.calendar.cgColor),
                    joinURL: Self.joinURL(in: [event.url?.absoluteString, event.location, event.notes]),
                    location: event.location,
                    notes: event.notes,
                    calendarName: event.calendar.title
                )
            }
    }

    // MARK: Queries

    func events(on day: Date) -> [CalendarEventItem] {
        Self.events(in: monthEvents, on: day)
    }

    func dotColors(on day: Date) -> [Color] {
        var seen: [Color] = []
        for event in events(on: day) where !seen.contains(event.color) {
            seen.append(event.color)
            if seen.count == 3 { break }
        }
        return seen
    }

    func imminentEvent(now: Date = Date()) -> CalendarEventItem? {
        Self.imminent(in: upcoming, now: now)
    }

    // MARK: Pure helpers (unit tested)

    /// Events that touch `day`, in start order.
    static func events(in events: [CalendarEventItem], on day: Date, calendar: Calendar = .current) -> [CalendarEventItem] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return events.filter { $0.start < interval.end && $0.end > interval.start }
    }

    /// The first timed event starting within `window` seconds, or that started under five minutes ago.
    static func imminent(in events: [CalendarEventItem], now: Date, within window: TimeInterval = 15 * 60) -> CalendarEventItem? {
        events
            .filter { !$0.isAllDay }
            .filter { $0.start.timeIntervalSince(now) <= window && now < $0.start.addingTimeInterval(5 * 60) }
            .min { $0.start < $1.start }
    }

    /// First meeting link (Meet, Zoom, Teams) found in the given texts.
    static func joinURL(in texts: [String?]) -> URL? {
        let pattern = #"https?://[^\s<>"']*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com)[^\s<>"']*"#
        for case let text? in texts {
            if let range = text.range(of: pattern, options: .regularExpression),
               let url = URL(string: String(text[range])) {
                return url
            }
        }
        return nil
    }
}
