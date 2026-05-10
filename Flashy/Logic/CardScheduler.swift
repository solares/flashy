import Foundation
import SwiftData

/// Result of choosing the next study card, including whether a **new** card should consume the daily new cap.
struct StudyPick {
    let card: Card
    /// Only meaningful for `card.state == .new`: increment `newCardsIntroducedToday` when first shown today.
    let countNewTowardDailyCap: Bool
}

enum CardScheduler {
    /// How many graded reviews one “Keep studying” session grants when there is no strict queue work.
    static let bonusSessionReviewCount = 25

    /// Front card plus peek edges (max five cards behind the active one).
    static let visibleStackSlots = 6

    /// Resets new-card pacing counters at local midnight.
    static func rolloverPacingIfNeeded(appState: AppState, now: Date = .now) {
        if DateRollover.isDifferentLocalDay(appState.newCardsIntroducedDay, than: now) {
            appState.newCardsIntroducedToday = 0
            appState.newCardsIntroducedDay = DateRollover.startOfLocalDay(for: now)
        }
    }

    /// Cards that count toward the FSRS **due** queue (excludes `.new`).
    static func isReviewDue(_ card: Card, now: Date) -> Bool {
        (card.state == .review || card.state == .learning) && card.nextDueAt <= now
    }

    static func retrievability(for card: Card, now: Date) -> Double {
        guard let last = card.lastReviewedAt else { return 1 }
        let elapsed = max(0, DateRollover.daysBetween(last, and: now))
        return FSRS.forgettingCurve(elapsedDays: elapsed, stability: card.stability)
    }

    /// True when the strict scheduler would still assign work (due reviews or new cards within daily cap).
    static func hasScheduledStudyWork(cards: [Card], appState: AppState, now: Date = .now) -> Bool {
        rolloverPacingIfNeeded(appState: appState, now: now)
        if cards.contains(where: { isReviewDue($0, now: now) }) {
            return true
        }
        if appState.newCardsPerDay > 0,
           appState.newCardsIntroducedToday < appState.newCardsPerDay,
           cards.contains(where: { $0.state == .new }) {
            return true
        }
        return false
    }

    /// Header metric: review/learning cards due before start of next local day.
    static func dueTodayCount(cards: [Card], now: Date = .now) -> Int {
        let tomorrow = DateRollover.startOfNextLocalDay(for: now)
        return cards.filter { card in
            (card.state == .review || card.state == .learning)
                && card.nextDueAt < tomorrow
        }.count
    }

    /// Strict queue (due reviews + new cards allowed by pacing), used for stacking when that set is non-empty.
    private static func strictStudyQueue(cards: [Card], appState: AppState, now: Date) -> [Card] {
        let reviewDue = cards
            .filter { isReviewDue($0, now: now) }
            .sorted { sortReviewQueue($0, $1, now: now) }
        let news = cards
            .filter { $0.state == .new }
            .sorted { sortNewQueue($0, $1) }
        let remainingSlots = max(0, appState.newCardsPerDay - appState.newCardsIntroducedToday)
        let allowedNew = Array(news.prefix(remainingSlots))
        return reviewDue + allowedNew
    }

    /// How many cards are in the strict queue (due reviews + eligible new cards) before bonus mode; useful for badges.
    static func scheduledStrictQueueCount(cards: [Card], appState: AppState, now: Date = .now) -> Int {
        rolloverPacingIfNeeded(appState: appState, now: now)
        return strictStudyQueue(cards: cards, appState: appState, now: now).count
    }

    /// Ordered cards for the stack (strict when possible; bonus session otherwise; empty when **caught up**).
    static func studyQueue(cards: [Card], appState: AppState, now: Date = .now) -> [Card] {
        rolloverPacingIfNeeded(appState: appState, now: now)
        let hasStrict = hasScheduledStudyWork(cards: cards, appState: appState, now: now)
        if !hasStrict, appState.effectiveBonusReviewBudget == 0, appState.currentCardId == nil {
            return []
        }

        var queue = strictStudyQueue(cards: cards, appState: appState, now: now)

        if queue.isEmpty, appState.effectiveBonusReviewBudget > 0 {
            let seen = Set(appState.bonusSeenCardIds)
            queue = relaxedPracticeOrdering(cards: cards.filter { !seen.contains($0.id) }, now: now)
        }

        if let cid = appState.currentCardId,
           let current = cards.first(where: { $0.id == cid }) {
            if !queue.contains(where: { $0.id == cid }) {
                queue.insert(current, at: 0)
            } else if let idx = queue.firstIndex(where: { $0.id == cid }) {
                let c = queue.remove(at: idx)
                queue.insert(c, at: 0)
            }
        }

        if queue.isEmpty {
            return []
        }

        let visibleLimit: Int
        if !hasStrict, appState.effectiveBonusReviewBudget > 0 {
            visibleLimit = min(visibleStackSlots, appState.effectiveBonusReviewBudget)
        } else {
            visibleLimit = visibleStackSlots
        }

        // Front card + up to five peek edges, all real queue cards (no padding to fake a deeper deck).
        return Array(queue.prefix(visibleLimit))
    }

    /// Next card to study, or `nil` if the library is empty or you are **caught up** (no bonus budget and no strict queue work).
    static func pickStudyCard(cards: [Card], appState: AppState, now: Date = .now, respectCurrentCard: Bool = true) -> StudyPick? {
        rolloverPacingIfNeeded(appState: appState, now: now)

        if respectCurrentCard,
           let cid = appState.currentCardId,
           let current = cards.first(where: { $0.id == cid }) {
            return StudyPick(
                card: current,
                countNewTowardDailyCap: shouldCountNewTowardDailyCap(current, appState: appState, now: now)
            )
        }

        let reviewDue = cards
            .filter { isReviewDue($0, now: now) }
            .sorted { sortReviewQueue($0, $1, now: now) }

        if let c = reviewDue.first {
            return StudyPick(card: c, countNewTowardDailyCap: false)
        }

        if appState.newCardsPerDay > 0, appState.newCardsIntroducedToday < appState.newCardsPerDay {
            let news = cards
                .filter { $0.state == .new }
                .sorted { sortNewQueue($0, $1) }
            if let c = news.first {
                return StudyPick(card: c, countNewTowardDailyCap: true)
            }
        }

        guard !cards.isEmpty else { return nil }

        guard appState.effectiveBonusReviewBudget > 0 else { return nil }

        let seen = Set(appState.bonusSeenCardIds)
        let bonusCandidates = cards.filter { !seen.contains($0.id) }
        guard !bonusCandidates.isEmpty else { return nil }

        let allNew = bonusCandidates.filter { $0.state == .new }.sorted { sortNewQueue($0, $1) }
        if let c = allNew.first {
            return StudyPick(card: c, countNewTowardDailyCap: false)
        }

        let mature = bonusCandidates
            .filter { $0.state == .review || $0.state == .learning }
            .sorted { sortReviewQueue($0, $1, now: now) }
        if let c = mature.first {
            return StudyPick(card: c, countNewTowardDailyCap: false)
        }

        if let c = bonusCandidates.first {
            return StudyPick(card: c, countNewTowardDailyCap: false)
        }
        return nil
    }

    /// Backward-compatible: first card from `pickStudyCard`, or `nil` if no cards.
    static func pickNext(cards: [Card], appState: AppState, now: Date = .now) -> Card? {
        pickStudyCard(cards: cards, appState: appState, now: now)?.card
    }

    /// Count a **new** card toward the daily new cap when first surfaced per local day (strict pacing only).
    static func beginDisplaying(_ card: Card, appState: AppState, now: Date = .now, countTowardDailyNewCap: Bool = true) {
        rolloverPacingIfNeeded(appState: appState, now: now)
        guard card.state == .new else { return }
        guard countTowardDailyNewCap else { return }
        if let shown = card.firstShownForPacingAt,
           DateRollover.calendar().isDate(shown, inSameDayAs: now) {
            return
        }
        card.firstShownForPacingAt = now
        appState.newCardsIntroducedToday += 1
        appState.newCardsIntroducedDay = DateRollover.startOfLocalDay(for: now)
    }

    // MARK: - Private

    /// Full relaxed practice ordering (new cards first, else reviews by due / retrievability).
    private static func relaxedPracticeOrdering(cards: [Card], now: Date) -> [Card] {
        let allNew = cards.filter { $0.state == .new }.sorted { sortNewQueue($0, $1) }
        if !allNew.isEmpty {
            return allNew
        }
        let mature = cards
            .filter { $0.state == .review || $0.state == .learning }
            .sorted { sortReviewQueue($0, $1, now: now) }
        if !mature.isEmpty {
            return mature
        }
        return cards.sorted { $0.id < $1.id }
    }

    /// Stable ordering so the stack does not reshuffle between SwiftUI frames (e.g. while dragging).
    private static func sortReviewQueue(_ a: Card, _ b: Card, now: Date) -> Bool {
        if a.nextDueAt != b.nextDueAt { return a.nextDueAt < b.nextDueAt }
        let ra = retrievability(for: a, now: now)
        let rb = retrievability(for: b, now: now)
        if ra != rb { return ra < rb }
        return a.id < b.id
    }

    private static func sortNewQueue(_ a: Card, _ b: Card) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    private static func shouldCountNewTowardDailyCap(_ card: Card, appState: AppState, now: Date) -> Bool {
        guard card.state == .new else { return false }
        guard appState.newCardsPerDay > 0 else { return false }
        return appState.newCardsIntroducedToday < appState.newCardsPerDay
    }

    /// Exposed for `StudyView` when re-syncing an already-selected card.
    static func shouldApplyNewCardDailyPacingWhenShowing(card: Card, appState: AppState, now: Date = .now) -> Bool {
        shouldCountNewTowardDailyCap(card, appState: appState, now: now)
    }
}
