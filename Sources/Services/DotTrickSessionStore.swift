import Foundation

struct DotTrickSessionStore {
    private let storage: JSONFileStorage

    init(
        fileURL: URL = Self.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.storage = JSONFileStorage(fileURL: fileURL, fileManager: fileManager)
    }

    func loadSessions() throws -> [DotTrickSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sessions = try storage.load([DotTrickSession].self, decoder: decoder) else {
            return []
        }
        return sessions.sorted(by: sortSessions)
    }

    func saveSessions(_ sessions: [DotTrickSession]) throws {
        let normalizedSessions = sessions
            .sorted(by: sortSessions)
            .enumerated()
            .map { index, session -> DotTrickSession in
                var normalized = session
                normalized.sortOrder = index
                return normalized
            }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try storage.save(normalizedSessions, encoder: encoder)
    }

    static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        JSONFileStorage.applicationSupportFileURL(
            named: "dot-trick-sessions.json",
            fileManager: fileManager
        )
    }

    private func sortSessions(_ lhs: DotTrickSession, _ rhs: DotTrickSession) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.sortOrder < rhs.sortOrder
    }
}
