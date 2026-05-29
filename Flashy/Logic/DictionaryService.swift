import Foundation

// MARK: - API models

struct RAEResponse: Codable {
    let data: RAEEntry
}

struct RAEEntry: Codable, Hashable {
    let word: String
    let meanings: [RAEMeaning]
}

struct RAEMeaning: Codable, Hashable {
    let origin: RAEOrigin?
    let senses: [RAESense]
}

struct RAEOrigin: Codable, Hashable {
    let raw: String
}

struct RAESense: Codable, Hashable {
    let meaningNumber: Int
    let category: String
    let description: String
    let synonyms: [String]?
    let antonyms: [String]?
    let crossReferences: [String]?

    enum CodingKeys: String, CodingKey {
        case meaningNumber = "meaning_number"
        case category
        case description
        case synonyms
        case antonyms
        case crossReferences = "cross_references"
    }
}

// MARK: - Errors

enum DictionaryError: LocalizedError {
    case invalidWord
    case notFound
    case rateLimited
    case serverError(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidWord:
            return "No se pudo leer la palabra."
        case .notFound:
            return "Palabra no encontrada en el diccionario."
        case .rateLimited:
            return "Demasiadas consultas. Espera un momento e inténtalo de nuevo."
        case .serverError:
            return "No se pudo consultar el diccionario."
        case .decodingFailed:
            return "No se pudieron leer los resultados."
        }
    }
}

// MARK: - Service

enum DictionaryService {
    private static let baseURL = "https://rae-api.com/api/words/"

    /// Strips surrounding punctuation and lowercases for lookup.
    static func normalize(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.trimmingCharacters(in: .punctuationCharacters)
        return stripped.lowercased()
    }

    static func lookup(_ word: String) async throws -> RAEEntry {
        let normalized = normalize(word)
        guard !normalized.isEmpty else { throw DictionaryError.invalidWord }

        if let cached = await DictionaryCache.shared.entry(for: normalized) {
            debugLog("cache hit word='\(normalized)'")
            return cached
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: baseURL + encoded)
        else {
            throw DictionaryError.invalidWord
        }

        debugLog("lookup word='\(word)' normalized='\(normalized)' url='\(url.absoluteString)'")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            debugLog("missing HTTP response for word='\(normalized)'")
            throw DictionaryError.serverError(-1)
        }

        debugLog("status=\(http.statusCode) word='\(normalized)' bytes=\(data.count)")
        switch http.statusCode {
        case 200:
            do {
                let entry = try JSONDecoder().decode(RAEResponse.self, from: data).data
                await DictionaryCache.shared.store(entry, for: normalized)
                return entry
            } catch {
                debugLog("decode failed word='\(normalized)' error='\(error)' body='\(bodySnippet(data))'")
                throw DictionaryError.decodingFailed
            }
        case 404:
            debugLog("not found word='\(normalized)' body='\(bodySnippet(data))'")
            throw DictionaryError.notFound
        case 429:
            debugLog("rate limited word='\(normalized)' body='\(bodySnippet(data))'")
            throw DictionaryError.rateLimited
        default:
            debugLog("server error status=\(http.statusCode) word='\(normalized)' body='\(bodySnippet(data))'")
            throw DictionaryError.serverError(http.statusCode)
        }
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[DictionaryService] \(message)")
        #endif
    }

    private static func bodySnippet(_ data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        return String(body.prefix(500))
    }
}

private actor DictionaryCache {
    static let shared = DictionaryCache()

    private let maxBytes = 25 * 1024 * 1024
    private var memory: [String: RAEEntry] = [:]
    private let directory: URL
    private let fileManager = FileManager.default

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = caches.appendingPathComponent("RAEDictionaryCache", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func entry(for word: String) -> RAEEntry? {
        if let cached = memory[word] {
            touch(word)
            return cached
        }

        let file = fileURL(for: word)
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(RAEEntry.self, from: data)
        else {
            return nil
        }

        memory[word] = entry
        touch(word)
        return entry
    }

    func store(_ entry: RAEEntry, for word: String) {
        memory[word] = entry
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: word), options: [.atomic])
        touch(word)
        pruneIfNeeded()
    }

    private func touch(_ word: String) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL(for: word).path)
    }

    private func fileURL(for word: String) -> URL {
        let encoded = Data(word.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(encoded).appendingPathExtension("json")
    }

    private func pruneIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var records: [(url: URL, modified: Date, size: Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }

        var total = records.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        records.sort { $0.modified < $1.modified }
        for record in records where total > maxBytes {
            try? fileManager.removeItem(at: record.url)
            total -= record.size
        }
    }
}
