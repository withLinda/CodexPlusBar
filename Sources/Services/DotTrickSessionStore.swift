import Foundation

struct DotTrickSessionStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = Self.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func loadSessions() throws -> [DotTrickSession] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions = try decoder.decode([DotTrickSession].self, from: data)
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

        try write(normalizedSessions)
    }

    func upsertSession(_ session: DotTrickSession) throws {
        var sessions = try loadSessions()

        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }

        try saveSessions(sessions)
    }

    func removeSession(id: UUID) throws {
        let sessions = try loadSessions().filter { $0.id != id }
        try saveSessions(sessions)
    }

    static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first

        let root = applicationSupportURL
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("CodexPlusBar", isDirectory: true)
            .appendingPathComponent("dot-trick-sessions.json", isDirectory: false)
    }

    private func write(_ sessions: [DotTrickSession]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessions)
        try data.write(to: fileURL, options: .atomic)
    }

    private func sortSessions(_ lhs: DotTrickSession, _ rhs: DotTrickSession) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.sortOrder < rhs.sortOrder
    }
}
