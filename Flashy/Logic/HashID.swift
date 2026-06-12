import CryptoKit
import Foundation

enum HashID {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// PRD §6: NFC, trim, collapse internal whitespace, lowercase (POSIX), hash front only.
    static func normalize(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        let trimmed = nfc.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = Self.collapseWhitespace(trimmed)
        return collapsed.lowercased(with: posix)
    }

    static func cardId(forFront front: String) -> String {
        let n = normalize(front)
        let digest = SHA256.hash(data: Data(n.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Stable pseudo-random order key for queue tie-breaking (varies by local day, stable within a day).
    static func daySeededOrderKey(cardId: String, day: Date) -> UInt64 {
        let dayString = daySeededDayString(for: day)
        let digest = SHA256.hash(data: Data("\(cardId):\(dayString)".utf8))
        return digest.withUnsafeBytes { raw in
            raw.load(as: UInt64.self)
        }
    }

    private static func daySeededDayString(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in s {
            if ch.isWhitespace {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }
}
