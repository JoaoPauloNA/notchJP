import SwiftUI

/// Spend card for the quotas page: today, last 30 days and a bar per day.
struct CostSummaryCard: View {
    private static let locale = Locale(identifier: "pt_BR")

    private var summary: CostSummary {
        CostSummary.make([
            ("Claude", CostHistoryStore.shared.report),
            ("Codex", CostHistoryStore.sharedCodex.report),
            ("Devin", CostHistoryStore.sharedDevin.report),
        ])
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Self.locale))
    }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gasto").font(.system(size: 15, weight: .semibold))
                Spacer()
                if CostHistoryStore.shared.isScanning { ProgressView().controlSize(.mini) }
            }
            if summary.isEmpty {
                Text(AppLanguage.text("Sem uso registrado nos últimos 30 dias."))
                    .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
            } else {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppLanguage.text("Hoje")).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                        Text(money(summary.today)).font(.system(size: 15, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppLanguage.text("30 dias")).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                        Text(money(summary.window)).font(.system(size: 15, weight: .bold))
                    }
                    Spacer(minLength: 0)
                    bars(summary.daily).frame(width: 96, height: 32)
                }
                if !summary.byProvider.isEmpty {
                    Text(summary.byProvider.map { "\($0.name) \(money($0.window))" }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .njpCard()
        .foregroundStyle(Color.primary)
        .help("Custo estimado a partir dos logs locais do Claude Code, Codex e Devin")
    }

    private func bars(_ values: [Double]) -> some View {
        let peak = max(values.max() ?? 0, 0.01)
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.suffix(30).enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(index == min(values.count, 30) - 1 ? NJP.accent : NJP.accent.opacity(0.45))
                    .frame(height: max(2, 32 * value / peak))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
