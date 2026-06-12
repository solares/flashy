import Foundation

/// FSRS-5-style update rules ported from FSRS4Anki scheduler (two grades: Again=1, Good=3).
/// Uses 20 weight coefficients from open-spaced-repetition defaults (indices 0–19) and a fixed decay of 0.5 (FSRS‑5).
enum FSRS {
    /// First 20 weights of the public FSRS defaults (excluding FSRS‑6 decay slot).
    private static let w: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666,
        0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658
    ]

    /// FSRS‑5 forgetting-curve decay (positive; used as `-decay` in the power law).
    private static let decay: Double = 0.5
    private static let maximumInterval: Double = 36500

    /// Pulls difficulty toward easy on each correct answer (two-button decks lack an Easy rating).
    private static let goodMeanReversionStrength: Double = 0.06

    private static var factor: Double {
        pow(0.9, 1.0 / (-decay)) - 1.0
    }

    /// Retrievability \(R\) for elapsed whole/partial days since last review.
    static func forgettingCurve(elapsedDays: Double, stability: Double) -> Double {
        let s = max(stability, 0.01)
        return pow(1.0 + factor * elapsedDays / s, -decay)
    }

    /// Next interval in **days** (minimum 1), no fuzz (deterministic).
    static func nextIntervalDays(stability: Double, retention: Double) -> Double {
        let s = max(stability, 0.01)
        let r = min(max(retention, 0.75), 0.99)
        let raw = s / factor * (pow(r, 1.0 / (-decay)) - 1.0)
        let rounded = max(1, min(raw, maximumInterval).rounded(.toNearestOrAwayFromZero))
        return rounded
    }

    static func applyReview(to card: Card, grade: Grade, now: Date, retention: Double) {
        let rating = grade == .again ? 1 : 3
        let elapsed = card.lastReviewedAt.map { max(0, DateRollover.daysBetween($0, and: now)) } ?? 0

        var d = card.difficulty
        var s = card.stability

        switch card.state {
        case .new:
            d = initDifficulty(rating: rating)
            s = initStability(rating: rating)
            if grade == .again {
                card.state = .learning
                card.lapses += 1
            } else {
                card.state = .review
            }

        case .learning:
            d = nextDifficulty(lastD: d, rating: rating)
            s = nextShortTermStability(s: s, rating: rating)
            if grade == .good {
                card.state = .review
            }
            if grade == .again {
                card.lapses += 1
            }

        case .review:
            let lastD = d
            let lastS = s
            let r = forgettingCurve(elapsedDays: elapsed, stability: lastS)
            if grade == .again {
                d = nextDifficulty(lastD: lastD, rating: rating)
                s = nextForgetStability(d: lastD, s: lastS, r: r)
                card.state = .learning
                card.lapses += 1
            } else {
                d = nextDifficulty(lastD: lastD, rating: rating)
                s = nextRecallStability(d: lastD, s: lastS, r: r, rating: rating)
                card.state = .review
            }
        }

        card.reps += 1
        card.lastReviewedAt = now
        let intervalDays = nextIntervalDays(stability: s, retention: retention)
        let fuzzedDays = fuzzIntervalDays(intervalDays)
        card.nextDueAt = now.addingTimeInterval(fuzzedDays * 86400)
        card.difficulty = round2(d)
        card.stability = round2(s)

        let event = ReviewEvent(
            at: now,
            grade: grade,
            elapsedDays: elapsed,
            stabilityAfter: card.stability
        )
        card.appendHistory(event)
    }

    // MARK: - Helpers

    private static func round2(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }

    private static func constrainDifficulty(_ difficulty: Double) -> Double {
        min(max(round2(difficulty), 1), 10)
    }

    private static func initDifficulty(rating: Int) -> Double {
        let w4 = w[4]
        let w5 = w[5]
        return constrainDifficulty(w4 - exp(w5 * Double(rating - 1)) + 1)
    }

    private static func initStability(rating: Int) -> Double {
        max(w[rating - 1], 0.1)
    }

    private static func linearDamping(deltaD: Double, oldD: Double) -> Double {
        deltaD * (10 - oldD) / 9
    }

    private static func meanReversion(initValue: Double, current: Double, strength: Double) -> Double {
        let k = min(max(strength, 0), 1)
        return k * initValue + (1 - k) * current
    }

    private static func nextDifficulty(lastD: Double, rating: Int) -> Double {
        let deltaD = -w[6] * (Double(rating) - 3)
        let nextD = lastD + linearDamping(deltaD: deltaD, oldD: lastD)
        let initEasy = initDifficulty(rating: 4)
        let strength = rating >= 3 ? goodMeanReversionStrength : w[7]
        return constrainDifficulty(meanReversion(initValue: initEasy, current: nextD, strength: strength))
    }

    /// Anki-style interval fuzz: spreads cards that would otherwise share the same interval.
    private static func fuzzIntervalDays(_ intervalDays: Double) -> Double {
        let base = max(1, intervalDays.rounded(.toNearestOrAwayFromZero))
        let spread = max(1, (base * 0.05).rounded(.toNearestOrAwayFromZero))
        let lower = max(1, base - spread)
        let upper = base + spread
        return max(1, Double.random(in: lower...upper))
    }

    private static func nextRecallStability(d: Double, s: Double, r: Double, rating: Int) -> Double {
        let hardPenalty = rating == 2 ? w[15] : 1
        let easyBonus = rating == 4 ? w[16] : 1
        let inner = 1
            + exp(w[8]) * (11 - d) * pow(s, -w[9])
            * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus
        return round2(s * inner)
    }

    private static func nextForgetStability(d: Double, s: Double, r: Double) -> Double {
        let sMin = s / exp(w[17] * w[18])
        let val = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return round2(min(val, sMin))
    }

    private static func nextShortTermStability(s: Double, rating: Int) -> Double {
        var sinc = exp(w[17] * (Double(rating) - 3 + w[18])) * pow(s, -w[19])
        if rating >= 3 {
            sinc = max(sinc, 1)
        }
        return round2(s * sinc)
    }
}
