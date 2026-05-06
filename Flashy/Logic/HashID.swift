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
