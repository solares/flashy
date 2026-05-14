import Foundation
import SwiftData

/// JSON-serializable snapshot of persisted app data (not SwiftData models).
struct FlashyBackup: Codable {
    var version: Int = 1
    var exportedAt: Date
    var cards: [CardBackup]
    var settings: AppStateBackup
}

struct CardBackup: Codable {
    var id: String
    var front: String
    var back: String
    var tagsRaw: String?
    var difficulty: Double
    var stability: Double
    var lapses: Int
    var reps: Int
    var stateRaw: String
    var createdAt: Date
    var lastReviewedAt: Date?
    var nextDueAt: Date
    var firstShownForPacingAt: Date?
    var history: [ReviewEvent]

    init(from card: Card) {
        id = card.id
        front = card.front
        back = card.back
        tagsRaw = card.tagsRaw
        difficulty = card.difficulty
        stability = card.stability
        lapses = card.lapses
        reps = card.reps
        stateRaw = card.stateRaw
        createdAt = card.createdAt
        lastReviewedAt = card.lastReviewedAt
        nextDueAt = card.nextDueAt
        firstShownForPacingAt = card.firstShownForPacingAt
        history = card.history
    }
}

struct AppStateBackup: Codable {
    var darkModeOverrideRaw: String?
    var newCardsPerDay: Int
    var retentionTarget: Double
    var hapticsEnabled: Bool
    var lastSessionDate: Date?
    var streakDays: Int
    var newCardsIntroducedToday: Int
    var newCardsIntroducedDay: Date?
    var currentCardId: String?
    var studyBackgroundRaw: String?
    var bonusReviewBudget: Int?
    var reverseModeEnabled: Bool?
    var bonusSeenCardIdsRaw: String?

    init(from app: AppState) {
        darkModeOverrideRaw = app.darkModeOverrideRaw
        newCardsPerDay = app.newCardsPerDay
        retentionTarget = app.retentionTarget
        hapticsEnabled = app.hapticsEnabled
        lastSessionDate = app.lastSessionDate
        streakDays = app.streakDays
        newCardsIntroducedToday = app.newCardsIntroducedToday
        newCardsIntroducedDay = app.newCardsIntroducedDay
        currentCardId = app.currentCardId
        studyBackgroundRaw = app.studyBackgroundRaw
        bonusReviewBudget = app.bonusReviewBudget
        reverseModeEnabled = app.reverseModeEnabled
        bonusSeenCardIdsRaw = app.bonusSeenCardIdsRaw
    }
}

enum BackupExporter {
    /// Writes a JSON backup to a temporary file and returns its URL for sharing.
    static func export(cards: [Card], appState: AppState) throws -> URL {
        let sortedCards = cards.sorted { $0.id < $1.id }
        let backup = FlashyBackup(
            exportedAt: Date(),
            cards: sortedCards.map { CardBackup(from: $0) },
            settings: AppStateBackup(from: appState)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(backup)

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = dayFormatter.string(from: Date())

        let dir = FileManager.default.temporaryDirectory
        var url = dir.appendingPathComponent("flashy-backup-\(day).json")
        var suffix = 0
        while FileManager.default.fileExists(atPath: url.path) {
            suffix += 1
            url = dir.appendingPathComponent("flashy-backup-\(day)-\(suffix).json")
        }

        try data.write(to: url, options: .atomic)
        return url
    }
}

enum BackupImporter {
    enum ImportError: Error {
        case unsupportedVersion(Int)
    }

    /// Replaces all `Card` rows and overwrites persisted fields on `appState` from backup JSON.
    static func importBackup(data: Data, modelContext: ModelContext, appState: AppState) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(FlashyBackup.self, from: data)
        guard backup.version == 1 else {
            throw ImportError.unsupportedVersion(backup.version)
        }

        let existing = try modelContext.fetch(FetchDescriptor<Card>())
        for c in existing {
            modelContext.delete(c)
        }

        for cb in backup.cards {
            modelContext.insert(card(from: cb))
        }

        apply(backup.settings, to: appState)
    }

    private static func card(from cb: CardBackup) -> Card {
        let card = Card(
            id: cb.id,
            front: cb.front,
            back: cb.back,
            tags: [],
            difficulty: cb.difficulty,
            stability: cb.stability,
            lapses: cb.lapses,
            reps: cb.reps,
            state: ReviewState(rawValue: cb.stateRaw) ?? .new,
            createdAt: cb.createdAt,
            lastReviewedAt: cb.lastReviewedAt,
            nextDueAt: cb.nextDueAt,
            firstShownForPacingAt: cb.firstShownForPacingAt,
            historyJSON: Data()
        )
        card.tagsRaw = cb.tagsRaw
        card.history = cb.history
        card.stateRaw = cb.stateRaw
        return card
    }

    private static func apply(_ s: AppStateBackup, to app: AppState) {
        app.darkModeOverrideRaw = s.darkModeOverrideRaw
        app.newCardsPerDay = min(50, max(0, s.newCardsPerDay))
        app.retentionTarget = [0.85, 0.9, 0.95].contains(s.retentionTarget) ? s.retentionTarget : 0.9
        app.hapticsEnabled = s.hapticsEnabled
        app.lastSessionDate = s.lastSessionDate
        app.streakDays = max(0, s.streakDays)
        app.newCardsIntroducedToday = max(0, s.newCardsIntroducedToday)
        app.newCardsIntroducedDay = s.newCardsIntroducedDay
        app.currentCardId = s.currentCardId
        app.studyBackgroundRaw = s.studyBackgroundRaw
        app.bonusReviewBudget = s.bonusReviewBudget
        app.reverseModeEnabled = s.reverseModeEnabled
        app.bonusSeenCardIdsRaw = s.bonusSeenCardIdsRaw
    }
}
