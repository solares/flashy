import Foundation
import SwiftData

/// One-off migration: lowers difficulty on cards that are proven known but stuck at high D.
enum DifficultyRescue {
    static let difficultyThreshold = 8.5
    static let minGoodStreak = 3
    static let targetDifficultyFloor = 6.0
    static let difficultyReduction = 3.0

    /// Runs the rescue pass once per install (guarded by `AppState.didRunDifficultyRescueV1`).
    /// Returns the number of cards adjusted.
    @discardableResult
    static func runIfNeeded(cards: [Card], appState: AppState) -> Int {
        guard !appState.effectiveDidRunDifficultyRescueV1 else { return 0 }

        var adjusted = 0
        for card in cards where shouldRescue(card) {
            card.difficulty = rescuedDifficulty(for: card.difficulty)
            adjusted += 1
        }

        appState.didRunDifficultyRescueV1 = true
        return adjusted
    }

    static func shouldRescue(_ card: Card) -> Bool {
        guard card.difficulty >= difficultyThreshold else { return false }
        guard trailingGoodStreak(card) >= minGoodStreak else { return false }
        let recent = card.history.suffix(minGoodStreak)
        return !recent.contains(where: { $0.grade == .again })
    }

    static func trailingGoodStreak(_ card: Card) -> Int {
        var streak = 0
        for event in card.history.reversed() {
            guard event.grade == .good else { break }
            streak += 1
        }
        return streak
    }

    static func rescuedDifficulty(for current: Double) -> Double {
        let lowered = max(targetDifficultyFloor, current - difficultyReduction)
        return (lowered * 100).rounded() / 100
    }
}

/// One-off migration: lifts any card whose persisted stability is non-finite or below the FSRS floor.
/// Targets the 24 cards written with `stability: 0` before the NaN-guard fix was introduced.
enum StabilityFloorRepair {
    /// Runs once per install (guarded by `AppState.didRunStabilityFloorRepairV1`).
    /// Returns the number of cards patched.
    @discardableResult
    static func runIfNeeded(cards: [Card], appState: AppState) -> Int {
        guard !appState.effectiveDidRunStabilityFloorRepairV1 else { return 0 }
        var patched = 0
        for card in cards where !card.stability.isFinite || card.stability < FSRS.minimumStability {
            card.stability = FSRS.minimumStability
            patched += 1
        }
        appState.didRunStabilityFloorRepairV1 = true
        return patched
    }
}

/// One-off migration: hard-resets cards stuck in the leech trap (high D, near-zero stability).
enum LeechRebalance {
    static let stabilityThreshold = 1.0
    static let difficultyThreshold = 7.5
    static let minReps = 3
    static let resetDifficulty = 5.0
    static let resetStability = 2.5
    static let dueSpreadMinDays = 2.0
    static let dueSpreadMaxDays = 16.0

    /// Runs the rebalance pass once per install (guarded by `AppState.didRunLeechRebalanceV1`).
    /// Returns the number of cards reset.
    @discardableResult
    static func runIfNeeded(cards: [Card], appState: AppState, now: Date = .now) -> Int {
        guard !appState.effectiveDidRunLeechRebalanceV1 else { return 0 }

        var adjusted = 0
        for card in cards where shouldRebalance(card) {
            applyHardReset(to: card, now: now)
            adjusted += 1
        }

        appState.didRunLeechRebalanceV1 = true
        return adjusted
    }

    static func shouldRebalance(_ card: Card) -> Bool {
        guard card.state == .review || card.state == .learning else { return false }
        guard card.stability < stabilityThreshold else { return false }
        guard card.difficulty >= difficultyThreshold else { return false }
        guard card.reps >= minReps else { return false }
        return true
    }

    static func applyHardReset(to card: Card, now: Date) {
        card.difficulty = resetDifficulty
        card.stability = resetStability
        card.state = .review
        card.lapses = 0
        card.lastReviewedAt = now
        card.nextDueAt = spreadDueDate(for: card, now: now)
    }

    /// Spreads reset cards across a multi-day window so they do not all re-enter the queue at once.
    static func spreadDueDate(for card: Card, now: Date) -> Date {
        let seedDay = DateRollover.startOfLocalDay(for: now)
        let key = HashID.daySeededOrderKey(cardId: card.id, day: seedDay)
        let fraction = Double(key) / Double(UInt64.max)
        let span = dueSpreadMaxDays - dueSpreadMinDays
        let days = dueSpreadMinDays + fraction * span
        return now.addingTimeInterval(days * 86400)
    }
}
