import Foundation
import SwiftData

struct CSVImportResult: Equatable {
    var inserted: Int
    var updated: Int
    var skippedDuplicates: Int
    var invalidRows: Int
}

enum CSVImporter {
    /// RFC 4180-ish CSV import. Upserts by `HashID.cardId(forFront:)`.
    @discardableResult
    static func `import`(
        data: Data,
        context: ModelContext,
        now: Date = .now
    ) throws -> CSVImportResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.notUTF8
        }

        var result = CSVImportResult(inserted: 0, updated: 0, skippedDuplicates: 0, invalidRows: 0)
        let rows = parseRows(from: text)
        guard !rows.isEmpty else { return result }

        let header = rows[0].map { $0.lowercased() }
        guard let frontIdx = header.firstIndex(of: "front"),
              let backIdx = header.firstIndex(of: "back")
        else {
            throw ImportError.missingRequiredColumns
        }
        let tagsIdx = header.firstIndex(of: "tags")

        for row in rows.dropFirst() {
            guard row.count > max(frontIdx, backIdx) else {
                result.invalidRows += 1
                continue
            }
            let rawFront = row[frontIdx]
            let rawBack = row[backIdx]
            let rawTags = tagsIdx.flatMap { idx -> String? in
                row.count > idx ? row[idx] : nil
            } ?? ""

            let front = rawFront.trimmingCharacters(in: .whitespacesAndNewlines)
            if front.isEmpty {
                result.invalidRows += 1
                continue
            }

            let cardId = HashID.cardId(forFront: front)
            let tags = parseTags(rawTags)
            let back = rawBack.trimmingCharacters(in: .whitespacesAndNewlines)

            let fd = FetchDescriptor<Card>(predicate: #Predicate { $0.id == cardId })
            if let existing = try context.fetch(fd).first {
                let sameBack = existing.back == back
                let sameTags = existing.tags == tags
                if sameBack && sameTags {
                    result.skippedDuplicates += 1
                } else {
                    existing.back = back
                    existing.tags = tags
                    result.updated += 1
                }
            } else {
                let card = Card(
                    id: cardId,
                    front: front,
                    back: back,
                    tags: tags,
                    difficulty: 5,
                    stability: 0.1,
                    lapses: 0,
                    reps: 0,
                    state: .new,
                    createdAt: now,
                    lastReviewedAt: nil,
                    nextDueAt: now
                )
                context.insert(card)
                result.inserted += 1
            }
        }

        try context.save()
        return result
    }

    enum ImportError: Error {
        case notUTF8
        case missingRequiredColumns
    }

    // MARK: - Tags

    private static func parseTags(_ s: String) -> [String] {
        s.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - RFC 4180 parsing

    /// Returns rows including header; each row is an array of unquoted fields.
    static func parseRows(from string: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(string)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r":
                    if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" {
                        i += 1
                    }
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                default:
                    field.append(c)
                }
            }
            i += 1
        }

        if inQuotes {
            // Malformed — treat as end
        }
        row.append(field)
        if !row.isEmpty, row != [""] {
            rows.append(row)
        }
        return rows
    }
}
