import Foundation

struct ProfileCatalogLoadResult {
    let profiles: [PlusProfile]
    let removedDuplicateCount: Int
}

struct ProfileCatalogStore {
    private let storage: JSONFileStorage

    init(
        fileURL: URL = Self.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.storage = JSONFileStorage(fileURL: fileURL, fileManager: fileManager)
    }

    func loadProfiles() throws -> [PlusProfile] {
        try loadProfilesWithReport().profiles
    }

    func loadProfilesWithReport() throws -> ProfileCatalogLoadResult {
        guard let profiles = try storage.load([PlusProfile].self) else {
            return ProfileCatalogLoadResult(profiles: [], removedDuplicateCount: 0)
        }
        let normalizedProfiles = Self.normalizedProfiles(profiles)
        return ProfileCatalogLoadResult(
            profiles: normalizedProfiles,
            removedDuplicateCount: profiles.count - normalizedProfiles.count
        )
    }

    func saveProfiles(_ profiles: [PlusProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try storage.save(Self.normalizedProfiles(profiles), encoder: encoder)
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
        JSONFileStorage.applicationSupportFileURL(
            named: "profiles.json",
            fileManager: fileManager
        )
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
