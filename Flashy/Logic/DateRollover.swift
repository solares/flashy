import Foundation

enum DateRollover {
    static func calendar() -> Calendar {
        var c = Calendar.current
        c.timeZone = .current
        return c
    }

    static func startOfLocalDay(for date: Date = .now) -> Date {
        calendar().startOfDay(for: date)
    }

    static func startOfNextLocalDay(for date: Date = .now) -> Date {
        let cal = calendar()
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
    }

    /// True if `day` is a different local calendar day than `reference` (typically stored pacing day).
    static func isDifferentLocalDay(_ day: Date?, than reference: Date) -> Bool {
        guard let day else { return true }
        return !calendar().isDate(day, inSameDayAs: reference)
    }

    static func daysBetween(_ from: Date, and to: Date) -> Double {
        to.timeIntervalSince(from) / 86400.0
    }
}
