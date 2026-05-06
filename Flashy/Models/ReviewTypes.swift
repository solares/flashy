import Foundation

enum ReviewState: String, Codable, CaseIterable {
    case new
    case learning
    case review
}

enum Grade: String, Codable, CaseIterable {
    case again
    case good
}

struct ReviewEvent: Codable, Equatable, Hashable {
    var at: Date
    var grade: Grade
    var elapsedDays: Double
    var stabilityAfter: Double
}
