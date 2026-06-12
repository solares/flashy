import Foundation
import SwiftData

@Model
final class AppState {
    /// "light" | "dark" | nil (system)
    var darkModeOverrideRaw: String?

    var newCardsPerDay: Int
    /// 0.85, 0.9, or 0.95
    var retentionTarget: Double
    var hapticsEnabled: Bool
    var lastSessionDate: Date?
    var streakDays: Int
    var newCardsIntroducedToday: Int
    var newCardsIntroducedDay: Date?

    /// Resume same card after relaunch
    var currentCardId: String?

    /// `FlashyTheme.StudyBackgroundPreset` raw value; `nil` → off white.
    var studyBackgroundRaw: String?

    /// Remaining graded reviews in the current “Keep studying” session. `nil` for rows migrated from older stores (= 0).
    var bonusReviewBudget: Int?

    /// Show the back first and flip to the front. `nil` for rows migrated from older stores (= false).
    var reverseModeEnabled: Bool?

    /// Newline-separated card ids reviewed in the current “Keep studying” round. `nil` for legacy rows / no seen cards.
    var bonusSeenCardIdsRaw: String?

    /// One-shot guard for `DifficultyRescue.runIfNeeded`. `nil` for legacy rows (= false).
    var didRunDifficultyRescueV1: Bool?

    init(
        darkModeOverrideRaw: String? = nil,
        newCardsPerDay: Int = 15,
        retentionTarget: Double = 0.9,
        hapticsEnabled: Bool = true,
        lastSessionDate: Date? = nil,
        streakDays: Int = 0,
        newCardsIntroducedToday: Int = 0,
        newCardsIntroducedDay: Date? = nil,
        currentCardId: String? = nil,
        studyBackgroundRaw: String? = nil,
        bonusReviewBudget: Int? = nil,
        reverseModeEnabled: Bool? = nil,
        bonusSeenCardIdsRaw: String? = nil,
        didRunDifficultyRescueV1: Bool? = nil
    ) {
        self.darkModeOverrideRaw = darkModeOverrideRaw
        self.newCardsPerDay = newCardsPerDay
        self.retentionTarget = retentionTarget
        self.hapticsEnabled = hapticsEnabled
        self.lastSessionDate = lastSessionDate
        self.streakDays = streakDays
        self.newCardsIntroducedToday = newCardsIntroducedToday
        self.newCardsIntroducedDay = newCardsIntroducedDay
        self.currentCardId = currentCardId
        self.studyBackgroundRaw = studyBackgroundRaw
        self.bonusReviewBudget = bonusReviewBudget
        self.reverseModeEnabled = reverseModeEnabled
        self.bonusSeenCardIdsRaw = bonusSeenCardIdsRaw
        self.didRunDifficultyRescueV1 = didRunDifficultyRescueV1
    }

    /// Use for scheduling UI; persisted optional is `nil` only on unmigrated legacy rows (treated as 0).
    var effectiveBonusReviewBudget: Int {
        bonusReviewBudget ?? 0
    }

    /// Use for study UI; persisted optional is `nil` only on unmigrated legacy rows (treated as false).
    var effectiveReverseModeEnabled: Bool {
        reverseModeEnabled ?? false
    }

    var effectiveDidRunDifficultyRescueV1: Bool {
        didRunDifficultyRescueV1 ?? false
    }

    var bonusSeenCardIds: [String] {
        get {
            bonusSeenCardIdsRaw?
                .split(separator: "\n")
                .map(String.init) ?? []
        }
        set {
            bonusSeenCardIdsRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n")
        }
    }
}
