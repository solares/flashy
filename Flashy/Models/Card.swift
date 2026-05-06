import Foundation
import SwiftData

@Model
final class Card {
    @Attribute(.unique) var id: String
    var front: String
    var back: String
    /// JSON-encoded `[String]`. Avoid storing `[String]` directly; CoreData can fault on `Array<String>`.
    var tagsRaw: String?

    var difficulty: Double
    var stability: Double
    var lapses: Int
    var reps: Int
    var stateRaw: String

    var createdAt: Date
    var lastReviewedAt: Date?
    var nextDueAt: Date

    /// First time this **new** card was surfaced for study in a local day (for daily new cap).
    var firstShownForPacingAt: Date?

    /// JSON-encoded `[ReviewEvent]` (SwiftData-friendly)
    var historyJSON: Data

    var state: ReviewState {
        get { ReviewState(rawValue: stateRaw) ?? .new }
        set { stateRaw = newValue.rawValue }
    }

    @Transient
    var tags: [String] {
        get {
            guard let tagsRaw,
                  let data = tagsRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard !newValue.isEmpty,
                  let data = try? JSONEncoder().encode(newValue),
                  let encoded = String(data: data, encoding: .utf8)
            else {
                tagsRaw = nil
                return
            }
            tagsRaw = encoded
        }
    }

    init(
        id: String,
        front: String,
        back: String,
        tags: [String] = [],
        difficulty: Double = 5.0,
        stability: Double = 0.1,
        lapses: Int = 0,
        reps: Int = 0,
        state: ReviewState = .new,
        createdAt: Date = .now,
        lastReviewedAt: Date? = nil,
        nextDueAt: Date = .now,
        firstShownForPacingAt: Date? = nil,
        historyJSON: Data = Data()
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.tagsRaw = nil
        self.difficulty = difficulty
        self.stability = stability
        self.lapses = lapses
        self.reps = reps
        self.stateRaw = state.rawValue
        self.createdAt = createdAt
        self.lastReviewedAt = lastReviewedAt
        self.nextDueAt = nextDueAt
        self.firstShownForPacingAt = firstShownForPacingAt
        self.historyJSON = historyJSON
        self.tags = tags
    }

    var history: [ReviewEvent] {
        get {
            (try? JSONDecoder().decode([ReviewEvent].self, from: historyJSON)) ?? []
        }
        set {
            historyJSON = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    func appendHistory(_ event: ReviewEvent, cap: Int = 100) {
        var h = history
        h.append(event)
        if h.count > cap {
            h = Array(h.suffix(cap))
        }
        history = h
    }
}
