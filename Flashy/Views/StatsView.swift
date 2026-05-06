import Charts
import SwiftData
import SwiftUI

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [Card]
    @Query private var appStates: [AppState]

    @State private var tagsExpanded = true

    private var app: AppState? { appStates.first }

    var body: some View {
        NavigationStack {
            List {
                todaySection
                last7Section
                overallSection
                if let app {
                    Section {
                        Text("Racha de \(app.streakDays) días")
                            .font(.body)
                    }
                }
                tagSection
            }
            .navigationTitle("Estadísticas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    private var todaySection: some View {
        Section("Hoy") {
            let m = StatsCalculator.todayMetrics(cards: cards, now: Date())
            HStack {
                metricTile(title: "Tarjetas repasadas", value: "\(m.reviewed)")
                metricTile(title: "Precisión", value: "\(m.accuracyPercent)%")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var last7Section: some View {
        Section("Últimos 7 días") {
            let pts = StatsCalculator.reviewsPerDayLast7(cards: cards, now: Date())
            Chart(pts, id: \.day) { p in
                BarMark(
                    x: .value("Día", p.day, unit: .day),
                    y: .value("Repasos", p.count)
                )
            }
            .frame(height: 180)
        }
    }

    private var overallSection: some View {
        Section("General") {
            let m = StatsCalculator.overallMetrics(cards: cards)
            HStack {
                metricTile(title: "Tarjetas totales", value: "\(m.totalCards)")
                metricTile(title: "Retención", value: "\(m.retentionPercent)%")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var tagSection: some View {
        Section {
            DisclosureGroup("Por etiqueta", isExpanded: $tagsExpanded) {
                let rows = StatsCalculator.tagRows(cards: cards)
                if rows.isEmpty {
                    Text("Sin etiquetas todavía")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.tag) { r in
                        HStack {
                            Text(r.tag)
                            Spacer()
                            Text("\(r.cardCount) tarjetas · \(r.retentionPercent)%")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
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

enum StatsCalculator {
    struct TodayMetrics {
        var reviewed: Int
        var accuracyPercent: Int
    }

    struct OverallMetrics {
        var totalCards: Int
        var retentionPercent: Int
    }

    struct DayCount: Hashable {
        var day: Date
        var count: Int
    }

    struct TagRow: Hashable {
        var tag: String
        var cardCount: Int
        var retentionPercent: Int
    }

    static func todayMetrics(cards: [Card], now: Date) -> TodayMetrics {
        let start = DateRollover.startOfLocalDay(for: now)
        var reviewed = 0
        var goods = 0
        for c in cards {
            for e in c.history where e.at >= start {
                reviewed += 1
                if e.grade == .good { goods += 1 }
            }
        }
        let acc = reviewed > 0 ? Int(round(Double(goods) / Double(reviewed) * 100)) : 0
        return TodayMetrics(reviewed: reviewed, accuracyPercent: acc)
    }

    static func reviewsPerDayLast7(cards: [Card], now: Date) -> [DayCount] {
        let cal = DateRollover.calendar()
        let startToday = DateRollover.startOfLocalDay(for: now)
        var days: [Date] = []
        for i in (0 ..< 7).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: startToday) {
                days.append(cal.startOfDay(for: d))
            }
        }
        var counts: [Date: Int] = Dictionary(uniqueKeysWithValues: days.map { ($0, 0) })
        for c in cards {
            for e in c.history {
                let d = cal.startOfDay(for: e.at)
                if counts[d] != nil {
                    counts[d, default: 0] += 1
                }
            }
        }
        return days.map { DayCount(day: $0, count: counts[$0, default: 0]) }
    }

    static func overallMetrics(cards: [Card]) -> OverallMetrics {
        var totalReviews = 0
        var goods = 0
        for c in cards {
            for e in c.history {
                totalReviews += 1
                if e.grade == .good { goods += 1 }
            }
        }
        let pct = totalReviews > 0 ? Int(round(Double(goods) / Double(totalReviews) * 100)) : 0
        return OverallMetrics(totalCards: cards.count, retentionPercent: pct)
    }

    static func tagRows(cards: [Card]) -> [TagRow] {
        struct Agg {
            var reviews = 0
            var goods = 0
            var cardCount = 0
        }
        var map: [String: Agg] = [:]
        let allTags = Set(cards.flatMap(\.tags))
        for t in allTags {
            var a = Agg()
            for c in cards where c.tags.contains(t) {
                a.cardCount += 1
                for e in c.history {
                    a.reviews += 1
                    if e.grade == .good { a.goods += 1 }
                }
            }
            map[t] = a
        }
        return map.map { tag, a in
            let pct = a.reviews > 0 ? Int(round(Double(a.goods) / Double(a.reviews) * 100)) : 0
            return TagRow(tag: tag, cardCount: a.cardCount, retentionPercent: pct)
        }
        .sorted { $0.cardCount > $1.cardCount }
    }
}
