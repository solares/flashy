import Charts
import SwiftData
import SwiftUI

struct UpcomingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var cards: [Card]

    @State private var selectedBucket: SelectedRecallBucket?

    var body: some View {
        let now = Date()
        let rows = UpcomingCalculator.recallBucketsToday(cards: cards, now: now)
        NavigationStack {
            List {
                recallChartSection(rows: rows)
            }
            .navigationTitle("Próximas")
            .navigationDestination(item: $selectedBucket) { selection in
                RecallBucketDetailView(
                    bucketTitle: selection.title,
                    cards: UpcomingCalculator.cards(inBucket: selection.id, cards: cards, now: now)
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func recallChartSection(rows: [UpcomingCalculator.RecallBucketRow]) -> some View {
        Section("Probabilidad de recuerdo (hoy)") {
            let total = rows.map(\.count).reduce(0, +)
            if total == 0 {
                Text("Nada por ahora")
                    .foregroundStyle(.secondary)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("Grupo", row.title),
                        y: .value("Tarjetas", row.count)
                    )
                    .foregroundStyle(UpcomingCalculator.bucketColor(for: row.id, colorScheme: colorScheme))
                }
                .chartXSelection(value: Binding(
                    get: { selectedBucket?.title },
                    set: { title in
                        guard let title,
                              let row = rows.first(where: { $0.title == title }) else {
                            selectedBucket = nil
                            return
                        }
                        selectedBucket = SelectedRecallBucket(id: row.id, title: row.title)
                    }
                ))
                .frame(height: 220)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Navigation

private struct SelectedRecallBucket: Identifiable, Hashable {
    var id: String
    var title: String
}

// MARK: - Bucket detail

private struct RecallBucketDetailView: View {
    let bucketTitle: String
    let cards: [Card]

    var body: some View {
        List {
            Section {
                let rows = UpcomingCalculator.tagBreakdown(for: cards)
                if rows.isEmpty {
                    Text("Sin tarjetas en este grupo")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.tag) { row in
                        HStack {
                            Text(row.tag)
                            Spacer()
                            Text("\(row.cardCount) tarjetas")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
            } header: {
                Text(bucketTitle)
            }
        }
        .navigationTitle(bucketTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Calculator

enum UpcomingCalculator {
    struct RecallBucketRow: Identifiable {
        var id: String
        var title: String
        var count: Int
    }

    struct TagBreakdownRow: Hashable {
        var tag: String
        var cardCount: Int
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

    static func cards(inBucket bucketId: String, cards: [Card], now: Date) -> [Card] {
        let endToday = DateRollover.startOfNextLocalDay(for: now)
        return cards.filter { card in
            guard card.state == .review || card.state == .learning,
                  card.nextDueAt < endToday else { return false }
            return recallBucketId(for: card, now: now) == bucketId
        }
    }

    static func tagBreakdown(for cards: [Card]) -> [TagBreakdownRow] {
        var counts: [String: Int] = [:]
        for card in cards {
            if card.tags.isEmpty {
                counts["Sin etiqueta", default: 0] += 1
            } else {
                for tag in card.tags {
                    counts[tag, default: 0] += 1
                }
            }
        }
        return counts.map { TagBreakdownRow(tag: $0.key, cardCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.cardCount != rhs.cardCount { return lhs.cardCount > rhs.cardCount }
                return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
    }

    static func bucketColor(for bucketId: String, colorScheme: ColorScheme) -> Color {
        switch bucketId {
        case "risk":
            return FlashyTheme.swipeRed.opacity(colorScheme == .dark ? 0.9 : 0.82)
        case "fragile":
            return Color.orange.opacity(colorScheme == .dark ? 0.9 : 0.82)
        case "strong":
            return FlashyTheme.accent(colorScheme: colorScheme).opacity(colorScheme == .dark ? 0.9 : 0.82)
        case "solid":
            return FlashyTheme.swipeGreen.opacity(colorScheme == .dark ? 0.9 : 0.82)
        default:
            return Color.secondary.opacity(0.5)
        }
    }

    private static func recallBucketId(for card: Card, now: Date) -> String {
        let r = CardScheduler.retrievability(for: card, now: now)
        if r < 0.5 { return "risk" }
        if r < 0.75 { return "fragile" }
        if r < 0.9 { return "strong" }
        return "solid"
    }
}
