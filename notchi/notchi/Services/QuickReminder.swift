import Foundation

nonisolated struct QuickReminder: Equatable {
    let title: String
    let due: Date
    static func parse(_ text: String, now: Date = Date()) -> QuickReminder? {
        let pattern = #"(?i)^\s*(.*?)\s+em\s+(\d{1,4})\s*(minutos?|min|horas?|h)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let titleRange = Range(match.range(at: 1), in: text), let numberRange = Range(match.range(at: 2), in: text),
              let unitRange = Range(match.range(at: 3), in: text), let count = Int(text[numberRange]), count > 0 else { return nil }
        let minutes = count * (text[unitRange].lowercased().hasPrefix("h") ? 60 : 1)
        guard minutes <= 10080 else { return nil }
        var title = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased() == "me avisar" || title.lowercased() == "me lembrar" { title = "Lembrete" }
        guard !title.isEmpty else { return nil }
        return QuickReminder(title: title, due: now.addingTimeInterval(Double(minutes) * 60))
    }
}
