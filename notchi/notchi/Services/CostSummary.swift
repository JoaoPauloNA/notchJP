import Foundation

/// Spend across Claude, Codex and Devin over the 30-day window.
struct CostSummary: Equatable {
    var today: Double = 0
    var window: Double = 0
    /// One value per day, oldest first, summed across providers.
    var daily: [Double] = []
    var byProvider: [(name: String, window: Double)] = []

    static func == (lhs: CostSummary, rhs: CostSummary) -> Bool {
        lhs.today == rhs.today && lhs.window == rhs.window && lhs.daily == rhs.daily
            && lhs.byProvider.map(\.name) == rhs.byProvider.map(\.name)
            && lhs.byProvider.map(\.window) == rhs.byProvider.map(\.window)
    }

    var isEmpty: Bool { window <= 0 }

    static func make(_ reports: [(name: String, report: DailyCostReport?)]) -> CostSummary {
        var perDay: [String: (date: Date, cost: Double)] = [:]
        var summary = CostSummary()
        for (name, report) in reports {
            guard let report else { continue }
            for entry in report.entries {
                perDay[entry.day, default: (entry.date, 0)].cost += entry.costUSD
            }
            summary.window += report.windowCostUSD
            summary.today += report.todayCostUSD
            if report.windowCostUSD > 0 { summary.byProvider.append((name, report.windowCostUSD)) }
        }
        summary.daily = perDay.values.sorted { $0.date < $1.date }.map(\.cost)
        return summary
    }
}
