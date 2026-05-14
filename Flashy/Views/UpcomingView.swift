import Charts
import SwiftData
import SwiftUI

struct UpcomingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var cards: [Card]
    @Query private var appStates: [AppState]

    private var app: AppState? { appStates.first }

    var body: some View {
        let now = Date()
        NavigationStack {
            List {
                heroSection(now: now)
                forecastSection(now: now)
                recallSection(now: now)
                urgentSection(now: now)
            }
            .navigationTitle("Próximas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func heroSection(now: Date) -> some View {
        Section {
            let h = UpcomingCalculator.heroCounts(cards: cards, app: app, now: now)
            HStack {
                metricTile(title: "Vencen hoy", value: "\(h.dueToday)")
                metricTile(title: "Vencidas ahora", value: "\(h.overdueNow)")
                metricTile(title: "Nuevas disponibles", value: "\(h.newAvailable)")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    @ViewBuilder
    private func forecastSection(now: Date) -> some View {
        Section("Pronóstico de 7 días") {
            let pts = UpcomingCalculator.forecast7(cards: cards, now: now)
            let accent = FlashyTheme.accent(colorScheme: colorScheme)
            let total = pts.map(\.count).reduce(0, +)
            if total == 0 {
                Text("Nada por ahora")
                    .foregroundStyle(.secondary)
            } else {
                Chart(pts) { p in
                    BarMark(
                        x: .value("Día", p.day, unit: .day),
                        y: .value("Repasos", p.count)
                    )
                    .foregroundStyle(p.isToday ? accent : Color.secondary.opacity(0.45))
                }
                .frame(height: 180)
            }
        }
    }

    @ViewBuilder
    private func recallSection(now: Date) -> some View {
        Section("Probabilidad de recuerdo (hoy)") {
            let rows = UpcomingCalculator.recallBucketsToday(cards: cards, now: now)
            let maxCount = rows.map(\.count).max() ?? 0
            let total = rows.map(\.count).reduce(0, +)
            if total == 0 {
                Text("Nada por ahora")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        RecallBarRow(row: row, maxCount: max(maxCount, 1))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func urgentSection(now: Date) -> some View {
        Section("Más urgentes") {
            let urgent = UpcomingCalculator.urgentCards(cards: cards, now: now, limit: 5)
            if urgent.isEmpty {
                Text("Nada por ahora")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(urgent) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.frontPreview)
                            .lineLimit(2)
                            .font(.body)
                        Spacer(minLength: 8)
                        Text("\(row.recallPercent)%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(UpcomingCalculator.shortDueLabel(nextDueAt: row.nextDueAt, now: now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Calculator

private enum UpcomingCalculator {
    struct HeroCounts {
        var dueToday: Int
        var overdueNow: Int
        var newAvailable: Int
    }

    struct ForecastDay: Identifiable {
        var id: Date { day }
        var day: Date
        var count: Int
        var isToday: Bool
    }

    struct RecallBucketRow: Identifiable {
        var id: String
        var title: String
        var count: Int
    }

    struct UrgentCardRow: Identifiable {
        var id: String
        var frontPreview: String
        var recallPercent: Int
        var nextDueAt: Date
    }

    static func heroCounts(cards: [Card], app: AppState?, now: Date) -> HeroCounts {
        guard let app else {
            return HeroCounts(dueToday: 0, overdueNow: 0, newAvailable: 0)
        }
        CardScheduler.rolloverPacingIfNeeded(appState: app, now: now)
        let endToday = DateRollover.startOfNextLocalDay(for: now)

        var dueToday = 0
        var overdueNow = 0
        for c in cards where c.state == .review || c.state == .learning {
            if c.nextDueAt < endToday {
                dueToday += 1
                if c.nextDueAt <= now {
                    overdueNow += 1
                }
            }
        }

        let newCount = cards.filter { $0.state == .new }.count
        let remainingSlots = max(0, app.newCardsPerDay - app.newCardsIntroducedToday)
        let newAvailable = app.newCardsPerDay > 0 ? min(remainingSlots, newCount) : 0

        return HeroCounts(dueToday: dueToday, overdueNow: overdueNow, newAvailable: newAvailable)
    }

    static func forecast7(cards: [Card], now: Date) -> [ForecastDay] {
        let cal = DateRollover.calendar()
        let startToday = DateRollover.startOfLocalDay(for: now)
        var days: [Date] = []
        for i in 0 ..< 7 {
            if let d = cal.date(byAdding: .day, value: i, to: startToday) {
                days.append(cal.startOfDay(for: d))
            }
        }
        let mature = cards.filter { $0.state == .review || $0.state == .learning }
        return days.enumerated().map { idx, dayStart in
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            let count = mature.filter { $0.nextDueAt >= dayStart && $0.nextDueAt < dayEnd }.count
            return ForecastDay(day: dayStart, count: count, isToday: idx == 0)
        }
    }

    static func recallBucketsToday(cards: [Card], now: Date) -> [RecallBucketRow] {
        let endToday = DateRollover.startOfNextLocalDay(for: now)
        let queue = cards.filter { card in
            (card.state == .review || card.state == .learning) && card.nextDueAt < endToday
        }
        var risk = 0, fragile = 0, strong = 0, solid = 0
        for c in queue {
            let r = CardScheduler.retrievability(for: c, now: now)
            if r < 0.5 { risk += 1 }
            else if r < 0.75 { fragile += 1 }
            else if r < 0.9 { strong += 1 }
            else { solid += 1 }
        }
        return [
            RecallBucketRow(id: "risk", title: "En riesgo", count: risk),
            RecallBucketRow(id: "fragile", title: "Frágil", count: fragile),
            RecallBucketRow(id: "strong", title: "Fuerte", count: strong),
            RecallBucketRow(id: "solid", title: "Sólido", count: solid),
        ]
    }

    static func urgentCards(cards: [Card], now: Date, limit: Int) -> [UrgentCardRow] {
        let endToday = DateRollover.startOfNextLocalDay(for: now)
        let queue = cards.filter { card in
            (card.state == .review || card.state == .learning) && card.nextDueAt < endToday
        }
        let sorted = queue.sorted { a, b in
            let ra = CardScheduler.retrievability(for: a, now: now)
            let rb = CardScheduler.retrievability(for: b, now: now)
            if ra != rb { return ra < rb }
            if a.nextDueAt != b.nextDueAt { return a.nextDueAt < b.nextDueAt }
            return a.id < b.id
        }
        return Array(sorted.prefix(limit)).map { c in
            let r = CardScheduler.retrievability(for: c, now: now)
            return UrgentCardRow(
                id: c.id,
                frontPreview: frontPreview(c.front),
                recallPercent: Int((r * 100).rounded()),
                nextDueAt: c.nextDueAt
            )
        }
    }

    static func shortDueLabel(nextDueAt: Date, now: Date) -> String {
        let cal = DateRollover.calendar()
        if nextDueAt <= now {
            return "Ahora"
        }
        if cal.isDate(nextDueAt, inSameDayAs: now) {
            let f = DateFormatter()
            f.locale = .current
            f.timeStyle = .short
            f.dateStyle = .none
            return f.string(from: nextDueAt)
        }
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: nextDueAt)
    }

    private static func frontPreview(_ front: String) -> String {
        let trimmed = front
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed.isEmpty ? "—" : trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 80)
        return String(trimmed[..<idx]) + "…"
    }
}

private struct RecallBarRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let row: UpcomingCalculator.RecallBucketRow
    let maxCount: Int

    var body: some View {
        let fill = FlashyTheme.accent(colorScheme: colorScheme)
        HStack(alignment: .center, spacing: 10) {
            Text(row.title)
                .font(.subheadline)
                .frame(width: 88, alignment: .leading)
            GeometryReader { geo in
                let w = maxCount > 0 ? CGFloat(row.count) / CGFloat(maxCount) * geo.size.width : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(fill.opacity(colorScheme == .dark ? 0.85 : 0.72))
                        .frame(width: max(4, w))
                }
            }
            .frame(height: 10)
            Text("\(row.count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
    }
}
