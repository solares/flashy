import XCTest
import SwiftData
@testable import Flashy

// MARK: - Helpers

private func makeCard(
    front: String = "hola",
    back: String = "hello",
    stability: Double = 2.0,
    difficulty: Double = 5.0,
    lapses: Int = 0,
    reps: Int = 0,
    state: ReviewState = .new,
    lastReviewedAt: Date? = nil,
    nextDueAt: Date = .now
) -> Card {
    let id = HashID.cardId(forFront: front)
    let card = Card(
        id: id,
        front: front,
        back: back,
        difficulty: difficulty,
        stability: stability,
        lapses: lapses,
        reps: reps,
        state: state,
        createdAt: Date(timeIntervalSinceReferenceDate: 0),
        lastReviewedAt: lastReviewedAt,
        nextDueAt: nextDueAt
    )
    return card
}

@MainActor
private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([Card.self, AppState.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

// MARK: - FSRS tests

final class FSRSTests: XCTestCase {

    // The primary regression: a review-state card with stability=0, graded Good, must not produce NaN.
    func test_stabilityZero_reviewGood_isFiniteAndAboveFloor() {
        let card = makeCard(stability: 0, difficulty: 7.24, lapses: 7, reps: 14, state: .review,
                            lastReviewedAt: Date())
        FSRS.applyReview(to: card, grade: .good, now: Date(), retention: 0.9)
        XCTAssertTrue(card.stability.isFinite, "stability must be finite after review-good from 0")
        XCTAssertGreaterThanOrEqual(card.stability, FSRS.minimumStability)
        XCTAssertTrue(card.nextDueAt.timeIntervalSince1970.isFinite, "nextDueAt must be finite")
    }

    // Same for learning-state card with stability=0.
    func test_stabilityZero_learningGood_isFinite() {
        let card = makeCard(stability: 0, difficulty: 6.0, lapses: 2, reps: 3, state: .learning,
                            lastReviewedAt: Date())
        FSRS.applyReview(to: card, grade: .good, now: Date(), retention: 0.9)
        XCTAssertTrue(card.stability.isFinite)
        XCTAssertGreaterThanOrEqual(card.stability, FSRS.minimumStability)
    }

    // 200-grade stress test: any sequence of Again/Good must never produce NaN or infinity.
    func test_neverNaN_longGradingLoop() {
        let card = makeCard(stability: 0, difficulty: 8.0, state: .review, lastReviewedAt: Date())
        let grades: [Grade] = [.again, .good, .good, .again, .good]
        var now = Date()
        for i in 0..<200 {
            let grade = grades[i % grades.count]
            FSRS.applyReview(to: card, grade: grade, now: now, retention: 0.9)
            XCTAssertTrue(card.stability.isFinite, "stability NaN at iteration \(i)")
            XCTAssertFalse(card.stability.isNaN, "stability NaN at iteration \(i)")
            XCTAssertGreaterThanOrEqual(card.stability, FSRS.minimumStability, "stability below floor at \(i)")
            XCTAssertTrue(card.nextDueAt.timeIntervalSince1970.isFinite, "nextDueAt non-finite at \(i)")
            now = card.nextDueAt
        }
    }

    // Repeated Again grades must never floor stability to 0 or below.
    func test_repeatedAgain_stabilityNeverZeroOrNegative() {
        let card = makeCard(stability: 4.0, difficulty: 7.0, state: .review, lastReviewedAt: Date())
        var now = Date()
        for i in 0..<100 {
            FSRS.applyReview(to: card, grade: .again, now: now, retention: 0.9)
            XCTAssertGreaterThan(card.stability, 0, "stability <= 0 at iteration \(i)")
            now = card.nextDueAt
        }
    }

    // New-state card graded Good should transition to review with finite stability >= floor.
    func test_newCard_good_isFinite() {
        let card = makeCard(state: .new)
        FSRS.applyReview(to: card, grade: .good, now: Date(), retention: 0.9)
        XCTAssertEqual(card.state, .review)
        XCTAssertTrue(card.stability.isFinite)
        XCTAssertGreaterThanOrEqual(card.stability, FSRS.minimumStability)
    }

    // New-state card graded Again should transition to learning.
    func test_newCard_again_transitionsToLearning() {
        let card = makeCard(state: .new)
        FSRS.applyReview(to: card, grade: .again, now: Date(), retention: 0.9)
        XCTAssertEqual(card.state, .learning)
        XCTAssertEqual(card.lapses, 1)
    }

    // forgettingCurve is finite for edge inputs including stability=0.
    func test_forgettingCurve_finiteForEdgeInputs() {
        XCTAssertTrue(FSRS.forgettingCurve(elapsedDays: 0, stability: 0).isFinite)
        XCTAssertTrue(FSRS.forgettingCurve(elapsedDays: 0, stability: 0.001).isFinite)
        XCTAssertTrue(FSRS.forgettingCurve(elapsedDays: 1000, stability: 0.01).isFinite)
        XCTAssertTrue(FSRS.forgettingCurve(elapsedDays: 1, stability: 36500).isFinite)
    }

    // nextIntervalDays is always >= 1.
    func test_nextIntervalDays_alwaysAtLeastOne() {
        let stabilities: [Double] = [0, 0.001, 0.01, 0.1, 1, 100, 36500]
        for s in stabilities {
            let interval = FSRS.nextIntervalDays(stability: s, retention: 0.9)
            XCTAssertGreaterThanOrEqual(interval, 1, "interval < 1 for stability=\(s)")
            XCTAssertTrue(interval.isFinite, "interval not finite for stability=\(s)")
        }
    }

    // history is recorded after every review.
    func test_historyAppended() {
        let card = makeCard(state: .review, lastReviewedAt: Date())
        XCTAssertEqual(card.history.count, 0)
        FSRS.applyReview(to: card, grade: .good, now: Date(), retention: 0.9)
        XCTAssertEqual(card.history.count, 1)
        XCTAssertEqual(card.history[0].grade, .good)
        XCTAssertTrue(card.history[0].stabilityAfter.isFinite)
    }

    // Self-heal: high-difficulty card with consecutive Goods gets difficulty/stability relief.
    func test_selfHeal_highDifficultyConsecutiveGoods() {
        let card = makeCard(stability: 5.0, difficulty: 8.5, state: .review, lastReviewedAt: Date())
        FSRS.applyReview(to: card, grade: .good, now: Date(), retention: 0.9)
        // First good — one less than selfHealMinGoodStreak; no heal yet
        let diffAfterFirst = card.difficulty
        let stabAfterFirst = card.stability

        let reviewDate = card.nextDueAt
        FSRS.applyReview(to: card, grade: .good, now: reviewDate, retention: 0.9)
        // After second consecutive Good on high-D card, difficulty should decrease
        XCTAssertLessThan(card.difficulty, diffAfterFirst, "self-heal should lower difficulty")
        XCTAssertGreaterThanOrEqual(card.stability, stabAfterFirst, "stability should not drop after heal")
    }
}

// MARK: - HashID tests

final class HashIDTests: XCTestCase {

    func test_normalize_trimsAndLowercases() {
        XCTAssertEqual(HashID.normalize("  Hola  "), "hola")
        XCTAssertEqual(HashID.normalize("CASA"), "casa")
    }

    func test_normalize_collapsesInternalWhitespace() {
        XCTAssertEqual(HashID.normalize("a  b   c"), "a b c")
    }

    func test_normalize_nfcComposition() {
        // é as combining e + combining accent vs precomposed é
        let combining = "e\u{0301}"
        let precomposed = "\u{00E9}"
        XCTAssertEqual(HashID.normalize(combining), HashID.normalize(precomposed))
    }

    func test_cardId_isDeterministic() {
        let id1 = HashID.cardId(forFront: "hablar")
        let id2 = HashID.cardId(forFront: "hablar")
        XCTAssertEqual(id1, id2)
    }

    func test_cardId_differentFronts_differentIds() {
        XCTAssertNotEqual(
            HashID.cardId(forFront: "hablar"),
            HashID.cardId(forFront: "escribir")
        )
    }

    func test_cardId_isHex64Chars() {
        let id = HashID.cardId(forFront: "hola")
        XCTAssertEqual(id.count, 64)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
    }

    func test_cardId_normalizesBeforeHashing() {
        // Trailing space and uppercase should produce the same id as trimmed lowercase.
        XCTAssertEqual(
            HashID.cardId(forFront: "  Hola  "),
            HashID.cardId(forFront: "hola")
        )
    }

    func test_daySeededOrderKey_stableWithinDay() {
        let day = DateRollover.startOfLocalDay(for: Date())
        let id = "abc123"
        let k1 = HashID.daySeededOrderKey(cardId: id, day: day)
        let k2 = HashID.daySeededOrderKey(cardId: id, day: day)
        XCTAssertEqual(k1, k2)
    }

    func test_daySeededOrderKey_changesBetweenDays() {
        let today = DateRollover.startOfLocalDay(for: Date())
        let tomorrow = DateRollover.startOfNextLocalDay(for: Date())
        let id = "abc123"
        let k1 = HashID.daySeededOrderKey(cardId: id, day: today)
        let k2 = HashID.daySeededOrderKey(cardId: id, day: tomorrow)
        XCTAssertNotEqual(k1, k2)
    }
}

// MARK: - DateRollover tests

final class DateRolloverTests: XCTestCase {

    func test_daysBetween_sameDate() {
        let d = Date()
        XCTAssertEqual(DateRollover.daysBetween(d, and: d), 0, accuracy: 0.0001)
    }

    func test_daysBetween_oneDay() {
        let d = Date()
        let next = d.addingTimeInterval(86400)
        XCTAssertEqual(DateRollover.daysBetween(d, and: next), 1.0, accuracy: 0.0001)
    }

    func test_isDifferentLocalDay_nilAlwaysTrue() {
        XCTAssertTrue(DateRollover.isDifferentLocalDay(nil, than: Date()))
    }

    func test_isDifferentLocalDay_sameDayFalse() {
        let now = Date()
        let startOfDay = DateRollover.startOfLocalDay(for: now)
        XCTAssertFalse(DateRollover.isDifferentLocalDay(startOfDay, than: now))
    }
}

// MARK: - CardScheduler tests

final class CardSchedulerTests: XCTestCase {

    private func makeAppState() -> AppState {
        AppState(newCardsPerDay: 10, newCardsIntroducedToday: 0)
    }

    func test_isReviewDue_pastDue() {
        let card = makeCard(state: .review, nextDueAt: Date(timeIntervalSinceNow: -3600))
        XCTAssertTrue(CardScheduler.isReviewDue(card, now: Date()))
    }

    func test_isReviewDue_futureDue() {
        let card = makeCard(state: .review, nextDueAt: Date(timeIntervalSinceNow: 3600 * 24))
        XCTAssertFalse(CardScheduler.isReviewDue(card, now: Date()))
    }

    func test_isReviewDue_newCardNotDue() {
        let card = makeCard(state: .new, nextDueAt: Date(timeIntervalSinceNow: -3600))
        XCTAssertFalse(CardScheduler.isReviewDue(card, now: Date()))
    }

    func test_studyQueue_emptyWhenNothingDue() {
        let appState = makeAppState()
        appState.newCardsPerDay = 0
        let card = makeCard(state: .review, nextDueAt: Date(timeIntervalSinceNow: 3600 * 24 * 7))
        let queue = CardScheduler.studyQueue(cards: [card], appState: appState, now: Date())
        XCTAssertTrue(queue.isEmpty)
    }

    func test_studyQueue_includesDueReviews() {
        let appState = makeAppState()
        let card = makeCard(state: .review, nextDueAt: Date(timeIntervalSinceNow: -60))
        let queue = CardScheduler.studyQueue(cards: [card], appState: appState, now: Date())
        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(queue.first?.id, card.id)
    }

    func test_studyQueue_respectsNewCardDailyCap() {
        let appState = makeAppState()
        appState.newCardsPerDay = 3
        appState.newCardsIntroducedToday = 3 // already at cap
        // Must anchor the pacing day to today; otherwise rolloverPacingIfNeeded resets the counter.
        appState.newCardsIntroducedDay = DateRollover.startOfLocalDay(for: Date())
        let cards = (0..<5).map { makeCard(front: "word\($0)", state: .new) }
        let queue = CardScheduler.studyQueue(cards: cards, appState: appState, now: Date())
        XCTAssertTrue(queue.isEmpty)
    }

    func test_studyQueue_allowsNewCardsUpToCap() {
        let appState = makeAppState()
        appState.newCardsPerDay = 3
        appState.newCardsIntroducedToday = 0
        let cards = (0..<5).map { makeCard(front: "word\($0)", state: .new,
                                           nextDueAt: Date(timeIntervalSinceReferenceDate: Double($0))) }
        let queue = CardScheduler.studyQueue(cards: cards, appState: appState, now: Date())
        XCTAssertLessThanOrEqual(queue.count, CardScheduler.visibleStackSlots)
        XCTAssertTrue(queue.allSatisfy { $0.state == .new })
    }

    func test_hasScheduledStudyWork_dueReview() {
        let appState = makeAppState()
        let card = makeCard(state: .review, nextDueAt: Date(timeIntervalSinceNow: -1))
        XCTAssertTrue(CardScheduler.hasScheduledStudyWork(cards: [card], appState: appState, now: Date()))
    }

    func test_hasScheduledStudyWork_noWorkWhenCaughtUp() {
        let appState = makeAppState()
        appState.newCardsPerDay = 0
        let card = makeCard(state: .review, nextDueAt: Date(timeIntervalSinceNow: 3600 * 24))
        XCTAssertFalse(CardScheduler.hasScheduledStudyWork(cards: [card], appState: appState, now: Date()))
    }

    func test_retrievability_finiteForZeroStabilityCard() {
        let card = makeCard(stability: 0, state: .review, lastReviewedAt: Date(timeIntervalSinceNow: -86400))
        let r = CardScheduler.retrievability(for: card, now: Date())
        XCTAssertTrue(r.isFinite, "retrievability must be finite even with stability=0")
    }

    func test_rolloverPacing_resetsCounterOnNewDay() {
        let appState = makeAppState()
        appState.newCardsIntroducedToday = 7
        // Set pacing day to yesterday
        appState.newCardsIntroducedDay = Date(timeIntervalSinceNow: -86400)
        CardScheduler.rolloverPacingIfNeeded(appState: appState, now: Date())
        XCTAssertEqual(appState.newCardsIntroducedToday, 0)
    }
}

// MARK: - DifficultyRescue tests

final class DifficultyRescueTests: XCTestCase {

    private func makeReviewedCard(difficulty: Double, goodStreak: Int, againAtEnd: Bool = false) -> Card {
        let card = makeCard(difficulty: difficulty, state: .review)
        var history: [ReviewEvent] = []
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<goodStreak {
            history.append(ReviewEvent(at: base.addingTimeInterval(Double(i) * 86400),
                                       grade: .good, elapsedDays: 1, stabilityAfter: 2.0))
        }
        if againAtEnd {
            history.append(ReviewEvent(at: base.addingTimeInterval(Double(goodStreak) * 86400),
                                       grade: .again, elapsedDays: 0, stabilityAfter: 0.5))
        }
        card.history = history
        return card
    }

    func test_shouldRescue_highDifficultyWithGoodStreak() {
        let card = makeReviewedCard(difficulty: 9.0, goodStreak: 3)
        XCTAssertTrue(DifficultyRescue.shouldRescue(card))
    }

    func test_shouldRescue_lowDifficultyNotRescued() {
        let card = makeReviewedCard(difficulty: 7.0, goodStreak: 5)
        XCTAssertFalse(DifficultyRescue.shouldRescue(card))
    }

    func test_shouldRescue_shortStreakNotRescued() {
        let card = makeReviewedCard(difficulty: 9.5, goodStreak: 1)
        XCTAssertFalse(DifficultyRescue.shouldRescue(card))
    }

    func test_shouldRescue_againAtEndNotRescued() {
        let card = makeReviewedCard(difficulty: 9.0, goodStreak: 3, againAtEnd: true)
        XCTAssertFalse(DifficultyRescue.shouldRescue(card))
    }

    func test_runIfNeeded_lowersDifficulty() {
        let appState = AppState()
        let card = makeReviewedCard(difficulty: 9.0, goodStreak: 4)
        let adjusted = DifficultyRescue.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(adjusted, 1)
        XCTAssertLessThan(card.difficulty, 9.0)
        XCTAssertGreaterThanOrEqual(card.difficulty, DifficultyRescue.targetDifficultyFloor)
        XCTAssertTrue(appState.effectiveDidRunDifficultyRescueV1)
    }

    func test_runIfNeeded_onlyRunsOnce() {
        let appState = AppState()
        let card = makeReviewedCard(difficulty: 9.0, goodStreak: 4)
        _ = DifficultyRescue.runIfNeeded(cards: [card], appState: appState)
        let diffAfterFirst = card.difficulty
        _ = DifficultyRescue.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(card.difficulty, diffAfterFirst, "second run must not change difficulty")
    }

    func test_rescuedDifficulty_neverBelowFloor() {
        let result = DifficultyRescue.rescuedDifficulty(for: 8.5)
        XCTAssertGreaterThanOrEqual(result, DifficultyRescue.targetDifficultyFloor)
    }

    func test_trailingGoodStreak_count() {
        let card = makeReviewedCard(difficulty: 9.0, goodStreak: 4)
        XCTAssertEqual(DifficultyRescue.trailingGoodStreak(card), 4)
    }
}

// MARK: - LeechRebalance tests

final class LeechRebalanceTests: XCTestCase {

    func test_shouldRebalance_highDifficultyLowStability() {
        let card = makeCard(stability: 0.3, difficulty: 8.0, lapses: 3, reps: 5, state: .review)
        XCTAssertTrue(LeechRebalance.shouldRebalance(card))
    }

    func test_shouldRebalance_newStateNotRebalanced() {
        let card = makeCard(stability: 0.3, difficulty: 8.0, lapses: 3, reps: 5, state: .new)
        XCTAssertFalse(LeechRebalance.shouldRebalance(card))
    }

    func test_shouldRebalance_highStabilityNotRebalanced() {
        let card = makeCard(stability: 5.0, difficulty: 8.0, lapses: 3, reps: 5, state: .review)
        XCTAssertFalse(LeechRebalance.shouldRebalance(card))
    }

    func test_shouldRebalance_lowDifficultyNotRebalanced() {
        let card = makeCard(stability: 0.3, difficulty: 5.0, lapses: 3, reps: 5, state: .review)
        XCTAssertFalse(LeechRebalance.shouldRebalance(card))
    }

    func test_shouldRebalance_fewRepsNotRebalanced() {
        let card = makeCard(stability: 0.3, difficulty: 8.0, lapses: 1, reps: 1, state: .review)
        XCTAssertFalse(LeechRebalance.shouldRebalance(card))
    }

    func test_runIfNeeded_resetsCard() {
        let appState = AppState()
        let card = makeCard(stability: 0.3, difficulty: 9.0, lapses: 5, reps: 8, state: .review)
        let count = LeechRebalance.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(card.difficulty, LeechRebalance.resetDifficulty)
        XCTAssertEqual(card.stability, LeechRebalance.resetStability)
        XCTAssertEqual(card.lapses, 0)
        XCTAssertTrue(appState.effectiveDidRunLeechRebalanceV1)
    }

    func test_runIfNeeded_onlyRunsOnce() {
        let appState = AppState()
        let card = makeCard(stability: 0.3, difficulty: 9.0, lapses: 5, reps: 8, state: .review)
        _ = LeechRebalance.runIfNeeded(cards: [card], appState: appState)
        card.difficulty = 9.0 // manually reset to confirm second run is skipped
        _ = LeechRebalance.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(card.difficulty, 9.0, "second run must not modify cards")
    }
}

// MARK: - StabilityFloorRepair tests

final class StabilityFloorRepairTests: XCTestCase {

    func test_repairsZeroStabilityCards() {
        let appState = AppState()
        let card = makeCard(stability: 0)
        let count = StabilityFloorRepair.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(card.stability, FSRS.minimumStability)
        XCTAssertTrue(appState.effectiveDidRunStabilityFloorRepairV1)
    }

    func test_repairsSubFloorCards() {
        let appState = AppState()
        let card = makeCard(stability: 0.001)
        let count = StabilityFloorRepair.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(card.stability, FSRS.minimumStability)
    }

    func test_doesNotTouchHealthyCards() {
        let appState = AppState()
        let card = makeCard(stability: 2.0)
        let count = StabilityFloorRepair.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(card.stability, 2.0)
    }

    func test_onlyRunsOnce() {
        let appState = AppState()
        let card = makeCard(stability: 0)
        _ = StabilityFloorRepair.runIfNeeded(cards: [card], appState: appState)
        card.stability = 0 // manually reset
        let count = StabilityFloorRepair.runIfNeeded(cards: [card], appState: appState)
        XCTAssertEqual(count, 0, "second run must be skipped")
        XCTAssertEqual(card.stability, 0, "card must not have been touched on second run")
    }
}

// MARK: - CSVImporter tests

final class CSVImporterTests: XCTestCase {

    @MainActor func test_parseRows_basicCSV() {
        let csv = "front,back\nhola,hello\ncasa,house"
        let rows = CSVImporter.parseRows(from: csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["front", "back"])
        XCTAssertEqual(rows[1], ["hola", "hello"])
        XCTAssertEqual(rows[2], ["casa", "house"])
    }

    @MainActor func test_parseRows_quotedFieldWithComma() {
        let csv = "front,back\n\"hello, world\",saludo"
        let rows = CSVImporter.parseRows(from: csv)
        XCTAssertEqual(rows[1][0], "hello, world")
    }

    @MainActor func test_parseRows_escapedQuote() {
        let csv = "front,back\n\"say \"\"hi\"\"\",decir hola"
        let rows = CSVImporter.parseRows(from: csv)
        XCTAssertEqual(rows[1][0], "say \"hi\"")
    }

    @MainActor func test_import_insertsNewCards() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let csv = "front,back,tags\nhola,hello,basic;greeting\ncasa,house,"
        let data = Data(csv.utf8)
        let result = try CSVImporter.import(data: data, context: context, now: Date())
        XCTAssertEqual(result.inserted, 2)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.skippedDuplicates, 0)
    }

    @MainActor func test_import_skipsDuplicates() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let csv = "front,back\nhola,hello"
        let data = Data(csv.utf8)
        _ = try CSVImporter.import(data: data, context: context, now: Date())
        let result = try CSVImporter.import(data: data, context: context, now: Date())
        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertEqual(result.inserted, 0)
    }

    @MainActor func test_import_updatesChangedBack() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let csv1 = "front,back\nhola,hello"
        _ = try CSVImporter.import(data: Data(csv1.utf8), context: context, now: Date())
        let csv2 = "front,back\nhola,hi"
        let result = try CSVImporter.import(data: Data(csv2.utf8), context: context, now: Date())
        XCTAssertEqual(result.updated, 1)
    }

    @MainActor func test_import_missingRequiredColumnThrows() {
        let container = try! makeInMemoryContainer()
        let context = container.mainContext
        let csv = "term,definition\nhola,hello"
        let data = Data(csv.utf8)
        XCTAssertThrowsError(try CSVImporter.import(data: data, context: context, now: Date()))
    }

    @MainActor func test_import_invalidRowCounted() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let csv = "front,back\n,hello\nhola,hi"
        let result = try CSVImporter.import(data: Data(csv.utf8), context: context, now: Date())
        XCTAssertEqual(result.invalidRows, 1)
        XCTAssertEqual(result.inserted, 1)
    }
}

// MARK: - Backup round-trip tests

final class BackupRoundTripTests: XCTestCase {

    @MainActor func test_exportImport_roundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        // Create source card with some FSRS state.
        let card = makeCard(front: "hablar", back: "to speak", stability: 3.5, difficulty: 5.5,
                            lapses: 1, reps: 7, state: .review,
                            lastReviewedAt: Date(timeIntervalSinceReferenceDate: 1_000_000),
                            nextDueAt: Date(timeIntervalSinceReferenceDate: 1_200_000))
        context.insert(card)

        let appState = AppState(newCardsPerDay: 20, retentionTarget: 0.9, hapticsEnabled: false,
                                streakDays: 5)
        context.insert(appState)
        try context.save()

        // Export.
        let url = try BackupExporter.export(cards: [card], appState: appState)
        let data = try Data(contentsOf: url)

        // Import into a fresh container.
        let container2 = try makeInMemoryContainer()
        let context2 = container2.mainContext
        let appState2 = AppState()
        context2.insert(appState2)
        try context2.save()

        try BackupImporter.importBackup(data: data, modelContext: context2, appState: appState2)

        let allCards = try context2.fetch(FetchDescriptor<Card>())
        XCTAssertEqual(allCards.count, 1)
        let restored = allCards[0]

        XCTAssertEqual(restored.front, card.front)
        XCTAssertEqual(restored.back, card.back)
        XCTAssertEqual(restored.stability, card.stability, accuracy: 0.001)
        XCTAssertEqual(restored.difficulty, card.difficulty, accuracy: 0.001)
        XCTAssertEqual(restored.lapses, card.lapses)
        XCTAssertEqual(restored.reps, card.reps)
        XCTAssertEqual(restored.stateRaw, card.stateRaw)
        XCTAssertEqual(appState2.newCardsPerDay, appState.newCardsPerDay)
        XCTAssertEqual(appState2.streakDays, appState.streakDays)
        XCTAssertFalse(appState2.hapticsEnabled)
    }

    @MainActor func test_export_withZeroStabilityCard_doesNotThrow() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let card = makeCard(front: "problema", back: "problem", stability: 0, state: .review)
        context.insert(card)
        let appState = AppState()
        context.insert(appState)
        try context.save()
        // Before the NaN-guard fix this would throw; now it must not.
        XCTAssertNoThrow(try BackupExporter.export(cards: [card], appState: appState))
    }

    @MainActor func test_export_json_isValidJSON() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let card = makeCard()
        context.insert(card)
        let appState = AppState()
        context.insert(appState)
        try context.save()
        let url = try BackupExporter.export(cards: [card], appState: appState)
        let data = try Data(contentsOf: url)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
