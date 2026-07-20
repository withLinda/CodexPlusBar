import Foundation

struct ProfileCatalogLoadResult {
    let profiles: [PlusProfile]
    let removedDuplicateCount: Int
}

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
        try loadProfilesWithReport().profiles
    }

    func loadProfilesWithReport() throws -> ProfileCatalogLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ProfileCatalogLoadResult(profiles: [], removedDuplicateCount: 0)
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let profiles = try decoder.decode([PlusProfile].self, from: data)
        let normalizedProfiles = Self.normalizedProfiles(profiles)
        return ProfileCatalogLoadResult(
            profiles: normalizedProfiles,
            removedDuplicateCount: profiles.count - normalizedProfiles.count
        )
    }

    func saveProfiles(_ profiles: [PlusProfile]) throws {
        try write(Self.normalizedProfiles(profiles))
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

    private static func normalizedProfiles(_ profiles: [PlusProfile]) -> [PlusProfile] {
        let orderedProfiles = profiles.enumerated().sorted { lhs, rhs in
            if lhs.element.sortOrder != rhs.element.sortOrder {
                return lhs.element.sortOrder < rhs.element.sortOrder
            }

            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt < rhs.element.createdAt
            }

            return lhs.offset < rhs.offset
        }
        var seenProfileIDs: Set<UUID> = []
        var uniqueProfiles: [PlusProfile] = []
        uniqueProfiles.reserveCapacity(orderedProfiles.count)

        for (_, profile) in orderedProfiles where seenProfileIDs.insert(profile.id).inserted {
            var normalized = profile
            normalized.sortOrder = uniqueProfiles.count
            uniqueProfiles.append(normalized)
        }

        return uniqueProfiles
    }
}
