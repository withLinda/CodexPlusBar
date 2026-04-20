import Foundation

struct ProfileCatalogStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = Self.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func loadProfiles() throws -> [PlusProfile] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let profiles = try decoder.decode([PlusProfile].self, from: data)
        return profiles.sorted(by: sortProfiles)
    }

    func saveProfiles(_ profiles: [PlusProfile]) throws {
        let normalizedProfiles = profiles
            .sorted(by: sortProfiles)
            .enumerated()
            .map { index, profile -> PlusProfile in
                var normalized = profile
                normalized.sortOrder = index
                return normalized
            }

        try write(normalizedProfiles)
    }

    func upsertProfile(_ profile: PlusProfile) throws {
        var profiles = try loadProfiles()

        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }

        try saveProfiles(profiles)
    }

    func removeProfile(id: UUID) throws {
        let profiles = try loadProfiles().filter { $0.id != id }
        try saveProfiles(profiles)
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
            .appendingPathComponent("profiles.json", isDirectory: false)
    }

    private func write(_ profiles: [PlusProfile]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }

    private func sortProfiles(_ lhs: PlusProfile, _ rhs: PlusProfile) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.sortOrder < rhs.sortOrder
    }
}
