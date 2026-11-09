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
    private let nativeSelectionIO: CloudJournalIO
    var directory: URL { storage.fileURL.deletingLastPathComponent() }
    // Local origin policy lives outside the backup-swapped account tree.
    var nativeSelectionDirectory: URL { CloudSyncPaths(root: directory.appendingPathExtension("native-selection")).root }
    var nativeSelectionFile: URL { nativeSelectionDirectory.appendingPathComponent("policy.json") }

    private func migrateLegacyNativeSelectionIfNeeded() throws {
        let legacyName = directory.appendingPathExtension("native-selection.json").lastPathComponent
        var info = stat()
        if lstat(directory.appendingPathExtension("native-selection.json").path, &info) != 0 {
            guard errno == ENOENT else { throw CloudPrivateFiles.systemError() }
            return
        }
        // Existing policy must pass the same private-file validation as new data.
        // Never chmod an unsafe source or drop its saved explicit removal intent.
        let root = try CloudPrivateFiles.openRoot(nativeSelectionDirectory, io: nativeSelectionIO)
        defer { close(root) }
        let lock = try CloudPrivateFiles.lock(in: root)
        defer { flock(lock, LOCK_UN); close(lock) }
        // The legacy source is a sibling of this verified private root. Access its
        // parent by descriptor, not by reopening a potentially redirected path.
        let parent = openat(root, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CloudPrivateFiles.systemError() }
        defer { close(parent) }
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw CloudJournalError.unsafePath
        }
        guard let bytes = try CloudPrivateFiles.read(legacyName, in: parent, limit: CloudSyncJournal.maximumJournalBytes) else { return }
        let legacy = try JSONDecoder().decode(NativeSelectionProtection.self, from: bytes)
        if let current = try readNativeSelection(in: root) {
            guard current == legacy else { throw OpenChamberSyncError.stateUnavailable }
        } else {
            try CloudPrivateFiles.replace("policy.json", bytes: bytes, in: root, io: nativeSelectionIO)
        }
        // Also safe after an uncertain destination commit: its read confirmed
        // durability above. A failed unlink can be retried without resetting policy.
        try CloudPrivateFiles.remove(legacyName, in: parent)
    }

    func nativeSelectionProtection() throws -> NativeSelectionProtection {
        try migrateLegacyNativeSelectionIfNeeded()
        let root: Int32
        do { root = try CloudPrivateFiles.openRoot(nativeSelectionDirectory, io: nativeSelectionIO, create: false) }
        catch let error as POSIXError where error.code == .ENOENT { return .init() }
        defer { close(root) }
        return try readNativeSelection(in: root) ?? .init()
    }

    func updateNativeProtection(cloudRemoved: Bool = false, cloudRemovedIdentities: [OpenCodeOpenAIIdentity] = [],
                                explicitlyRemoved: [OpenCodeOpenAIIdentity] = []) throws {
        try migrateLegacyNativeSelectionIfNeeded()
        guard cloudRemoved || !explicitlyRemoved.isEmpty else { _ = try nativeSelectionProtection(); return }
        let root = try CloudPrivateFiles.openRoot(nativeSelectionDirectory, io: nativeSelectionIO)
        defer { close(root) }
        let lock = try CloudPrivateFiles.lock(in: root)
        defer { flock(lock, LOCK_UN); close(lock) }
        let previous = try readNativeSelection(in: root) ?? .init()
        var next = previous
        if cloudRemoved {
            next.cloudRemovalObserved = true
            // A relinked identity removed remotely is protected again. Unrelated
            // deferred local removals retain their explicit authorization.
            next.explicitlyRemoved.removeAll { old in cloudRemovedIdentities.contains { $0.matches(old) } }
        }
        for identity in explicitlyRemoved where !next.explicitlyRemoved.contains(where: { $0.matches(identity) }) {
            next.explicitlyRemoved.append(identity)
        }
        if next != previous {
            let bytes = try JSONEncoder().encode(next)
            guard bytes.count <= CloudSyncJournal.maximumJournalBytes else { throw CloudJournalError.tooLarge }
            try CloudPrivateFiles.replace("policy.json", bytes: bytes, in: root, io: nativeSelectionIO)
        }
    }

    private func readNativeSelection(in root: Int32) throws -> NativeSelectionProtection? {
        guard let bytes = try CloudPrivateFiles.read("policy.json", in: root, limit: CloudSyncJournal.maximumJournalBytes) else { return nil }
        let policy = try JSONDecoder().decode(NativeSelectionProtection.self, from: bytes)
        // A visible rename is not proof that the previous commit was durable.
        do {
            try nativeSelectionIO.before(.recoverySync, "policy.json")
            try CloudPrivateFiles.synchronize("policy.json", in: root)
        } catch { throw CloudJournalError.commitUncertain("policy.json") }
        return policy
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
        try migrateLegacyNativeSelectionIfNeeded()
        guard onlyStartupScaffold, !FileManager.default.fileExists(atPath: nativeSelectionDirectory.path) else {
            throw CloudJournalError.catalogUnavailable
        }
        try saveProfiles([])
    }

    init(
        fileURL: URL = Self.defaultFileURL(),
        fileManager: FileManager = .default,
        nativeSelectionIO: CloudJournalIO = .init()
    ) {
        self.storage = JSONFileStorage(fileURL: fileURL, fileManager: fileManager)
        self.nativeSelectionIO = nativeSelectionIO
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
