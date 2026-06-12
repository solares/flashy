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
