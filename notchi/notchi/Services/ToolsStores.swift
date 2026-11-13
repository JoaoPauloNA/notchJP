import AppKit
import Combine
import EventKit
import Foundation

/// Folders the user pinned as one-tap project shortcuts.
@MainActor
final class ProjectShortcutsStore: ObservableObject {
    static let shared = ProjectShortcutsStore()
    @Published private(set) var paths: [String]

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: NJPSettings.projectShortcutsKey) ?? []
    }

    func add(_ urls: [URL]) {
        paths = Self.merging(urls.map(\.path), into: paths, limit: 8)
        persist()
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        persist()
    }

    private func persist() { UserDefaults.standard.set(paths, forKey: NJPSettings.projectShortcutsKey) }

    /// New paths first-come last, no duplicates, capped.
    static func merging(_ new: [String], into current: [String], limit: Int) -> [String] {
        var result = current
        for path in new where !result.contains(path) { result.append(path) }
        return Array(result.prefix(limit))
    }

    static func open(_ path: String, withBundle bundle: String? = "com.googlecode.iterm2") {
        let url = URL(fileURLWithPath: path)
        let workspace = NSWorkspace.shared
        if let bundle, let app = workspace.urlForApplication(withBundleIdentifier: bundle) {
            workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            workspace.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Files parked on the shelf; they stay where they are, the shelf only remembers the paths.
@MainActor
final class FileShelfStore: ObservableObject {
    static let shared = FileShelfStore()
    @Published private(set) var paths: [String]

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: NJPSettings.fileShelfKey) ?? []
    }

    /// Only files that still exist.
    var items: [URL] {
        paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        paths = ProjectShortcutsStore.merging(urls.map(\.path), into: paths, limit: 12)
        UserDefaults.standard.set(paths, forKey: NJPSettings.fileShelfKey)
    }

    func remove(_ url: URL) {
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: NJPSettings.fileShelfKey)
    }
}

/// Last texts copied. Opt-in, in memory only, and it ignores password managers.
@MainActor
final class ClipboardHistoryService: ObservableObject {
    static let shared = ClipboardHistoryService()
    @Published private(set) var items: [String] = []
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount

    private init() {}

    func apply() {
        if NJPSettings.clipboardHistory { start() } else { stop(); items = [] }
    }

    private func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    func copyBack(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChange = NSPasteboard.general.changeCount
        items = Self.insert(text, into: items)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        guard Self.shouldRecord(types: pasteboard.types ?? []),
              let text = pasteboard.string(forType: .string) else { return }
        items = Self.insert(text, into: items)
    }

    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "com.agilebits.onepassword", "com.1password.1password", "de.petermaurer.TransientPasteboardType",
    ]

    static func shouldRecord(types: [NSPasteboard.PasteboardType]) -> Bool {
        !types.contains { concealedTypes.contains($0.rawValue) }
    }

    /// Most recent first, no duplicates, blank text ignored, long text trimmed.
    static func insert(_ text: String, into list: [String], limit: Int = 12) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        let value = trimmed.count > 400 ? String(trimmed.prefix(400)) : trimmed
        return Array(([value] + list.filter { $0 != value }).prefix(limit))
    }
}

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let listName: String
}

/// Reminders due today or overdue, from the Mac's Reminders app.
@MainActor
final class RemindersService: ObservableObject {
    static let shared = RemindersService()
    @Published private(set) var access: CalendarEventsService.Access = .unknown
    @Published private(set) var items: [ReminderItem] = []
    private let store = EKEventStore()

    private init() { updateAccess() }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        case .notDetermined: access = .unknown
        @unknown default: access = .unknown
        }
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToReminders()
        refresh()
    }

    func refresh() {
        updateAccess()
        guard access == .granted else { items = []; return }
        let endOfToday = Calendar.current.dateInterval(of: .day, for: Date())?.end
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        store.fetchReminders(matching: predicate) { reminders in
            let mapped = (reminders ?? []).map {
                ReminderItem(id: $0.calendarItemIdentifier, title: $0.title ?? "Sem título",
                             due: $0.dueDateComponents?.date, listName: $0.calendar.title)
            }
            Task { @MainActor in RemindersService.shared.items = Self.ordered(mapped) }
        }
    }

    func create(_ text: String, now: Date = Date()) -> String? {
        updateAccess()
        guard access == .granted else { return "Permita o acesso aos lembretes primeiro." }
        guard let parsed = QuickReminder.parse(text, now: now) else { return "Use, por exemplo: beber água em 20 minutos (até 7 dias)." }
        guard let calendar = store.defaultCalendarForNewReminders() else { return "Crie uma lista no app Lembretes primeiro." }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar; reminder.title = parsed.title
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed.due)
        reminder.addAlarm(EKAlarm(absoluteDate: parsed.due))
        do { try store.save(reminder, commit: true); refresh(); return nil }
        catch { return "Não foi possível salvar: " + error.localizedDescription }
    }

    func complete(_ item: ReminderItem) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        if (try? store.save(reminder, commit: true)) != nil {
            items.removeAll { $0.id == item.id }
        }
    }

    /// Earliest due first, undated last, at most eight.
    static func ordered(_ items: [ReminderItem]) -> [ReminderItem] {
        Array(items.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            default: $0.title < $1.title
            }
        }.prefix(8))
    }
}
