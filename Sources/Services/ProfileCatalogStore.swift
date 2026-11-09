import Darwin
import Foundation

struct ProfileCatalogLoadResult {
    let profiles: [PlusProfile]
    let removedDuplicateCount: Int
    let sourceExists: Bool
}

struct NativeSelectionProtection: Codable, Equatable, Sendable {
    var cloudRemovalObserved = false
    var explicitlyRemoved: [OpenCodeOpenAIIdentity] = []

    func protects(_ identity: OpenCodeOpenAIIdentity) -> Bool {
        cloudRemovalObserved && !explicitlyRemoved.contains { $0.matches(identity) }
    }
}

struct ProfileCatalogStore {
    private let storage: JSONFileStorage
    var directory: URL { storage.fileURL.deletingLastPathComponent() }
    // Local origin policy lives outside the backup-swapped account tree.
    var nativeSelectionFile: URL { directory.appendingPathExtension("native-selection.json") }

    func nativeSelectionProtection() throws -> NativeSelectionProtection {
        try JSONFileStorage(fileURL: nativeSelectionFile).load(NativeSelectionProtection.self) ?? .init()
    }

    func updateNativeProtection(cloudRemoved: Bool = false, explicitlyRemoved: [OpenCodeOpenAIIdentity] = []) throws {
        let previous = try nativeSelectionProtection()
        var next = previous
        if cloudRemoved {
            next.cloudRemovalObserved = true
            next.explicitlyRemoved = []
        }
        if next.cloudRemovalObserved {
            for identity in explicitlyRemoved where !next.explicitlyRemoved.contains(where: { $0.matches(identity) }) {
                next.explicitlyRemoved.append(identity)
            }
        }
        if next != previous { try JSONFileStorage(fileURL: nativeSelectionFile).save(next) }
        guard FileManager.default.fileExists(atPath: nativeSelectionFile.path) else { return }
        // Retry durability even if a prior replacement became visible before fsync failed.
        let file = try FileHandle(forWritingTo: nativeSelectionFile)
        defer { try? file.close() }
        try file.synchronize()
        let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }

    func initializeFreshCatalog() throws {
        guard try !loadProfilesWithReport().sourceExists else { return }
        let contents = FileManager.default.fileExists(atPath: directory.path)
            ? try FileManager.default.contentsOfDirectory(atPath: directory.path) : []
        // Normal first launch creates this empty browser root before cloud starts.
        // Any browser contents or other account artifacts still mean recovery.
        let onlyStartupScaffold = try contents.allSatisfy { name in
            guard name == "ChromeProfiles" else { return false }
            let child = directory.appendingPathComponent(name)
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
            return try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty
        }
        guard onlyStartupScaffold, !FileManager.default.fileExists(atPath: nativeSelectionFile.path) else {
            throw CloudJournalError.catalogUnavailable
        }
        try saveProfiles([])
    }

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
            return ProfileCatalogLoadResult(profiles: [], removedDuplicateCount: 0, sourceExists: false)
        }
        let normalizedProfiles = Self.normalizedProfiles(profiles)
        return ProfileCatalogLoadResult(
            profiles: normalizedProfiles,
            removedDuplicateCount: profiles.count - normalizedProfiles.count,
            sourceExists: true
        )
    }

    func saveProfiles(_ profiles: [PlusProfile]) throws {
        // Distinguish a never-created catalog from a subsequently missing empty one.
        let marker = directory.appendingPathComponent(".catalog-created")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: marker, options: .atomic)
        }
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

    static func normalizedProfiles(_ profiles: [PlusProfile]) -> [PlusProfile] {
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
