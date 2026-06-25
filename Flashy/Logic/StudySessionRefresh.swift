import Foundation
import SwiftData

/// When the study queue should be reconciled against the scheduler.
enum StudySessionRefreshPhase {
    /// Foreground / library change — may assign or repair the active card.
    case warmStart
    /// While the user is on a card — never change the active card; peek stack only (via clock bump).
    case passivePeek
}

enum StudySessionRefresh {
    /// How often to refresh peek cards behind the active one during play.
    static let passivePeekInterval: TimeInterval = 90

    /// Reconcile `AppState` with the scheduler for the given phase.
    /// - Returns: Whether any persisted session fields were mutated.
    @discardableResult
    static func apply(
        appState: AppState,
        cards: [Card],
        now: Date = .now,
        phase: StudySessionRefreshPhase
    ) -> Bool {
        CardScheduler.rolloverPacingIfNeeded(appState: appState, now: now)

        let hasStrict = CardScheduler.hasScheduledStudyWork(cards: cards, appState: appState, now: now)
        let allowPick = hasStrict || appState.effectiveBonusReviewBudget > 0

        if !allowPick {
            guard appState.currentCardId != nil else { return false }
            appState.currentCardId = nil
            return true
        }

        switch phase {
        case .passivePeek:
            // Mid-play: keep the card the user is studying; do not auto-assign.
            return false

        case .warmStart:
            return reconcileActiveCard(appState: appState, cards: cards, now: now, hasStrict: hasStrict)
        }
    }

    /// True when the visible stack can be shown without a front-card swap.
    static func isStackDisplayReady(appState: AppState, cards: [Card], queue: [Card], now: Date = .now) -> Bool {
        let inSession =
            CardScheduler.hasScheduledStudyWork(cards: cards, appState: appState, now: now)
                || appState.effectiveBonusReviewBudget > 0
        guard inSession else { return true }
        guard let activeId = appState.currentCardId else { return false }
        return queue.first?.id == activeId
    }

    // MARK: - Private

    private static func reconcileActiveCard(
        appState: AppState,
        cards: [Card],
        now: Date,
        hasStrict: Bool
    ) -> Bool {
        var changed = false

        if let id = appState.currentCardId,
           cards.first(where: { $0.id == id }) == nil {
            appState.currentCardId = nil
            changed = true
        }

        if appState.currentCardId == nil {
            if let pick = CardScheduler.pickStudyCard(cards: cards, appState: appState, now: now) {
                appState.currentCardId = pick.card.id
                CardScheduler.beginDisplaying(
                    pick.card,
                    appState: appState,
                    now: now,
                    countTowardDailyNewCap: pick.countNewTowardDailyCap
                )
                changed = true
            } else if !hasStrict {
                appState.bonusReviewBudget = 0
                appState.bonusSeenCardIds = []
                changed = true
            }
        } else if let id = appState.currentCardId,
                  let card = cards.first(where: { $0.id == id }) {
            CardScheduler.beginDisplaying(
                card,
                appState: appState,
                now: now,
                countTowardDailyNewCap: CardScheduler.shouldApplyNewCardDailyPacingWhenShowing(
                    card: card,
                    appState: appState,
                    now: now
                )
            )
        }

        return changed
    }
}
