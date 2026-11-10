import Foundation
import Darwin

/// Destination-only seed intent. Store UUIDs never enter CloudKit payloads.
struct CloudBrowserSeedStore: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let profileID: UUID
        let storeID: UUID
        let payload: CloudSessionPayload
        var chromeSeedPending = true
    }
    let directory: URL
    // Recovery is private device-local state outside the backup-swapped account
    // tree, matching CloudPrivateFiles' path contract and native-selection policy.
    init(directory: URL = ProfileCatalogStore.defaultFileURL().deletingLastPathComponent().appendingPathExtension("browser-recovery")) {
        self.directory = CloudSyncPaths(root: directory).root
    }
    func save(_ payload: CloudSessionPayload, for profile: PlusProfile, chromeSeedPending: Bool = true) throws {
        guard profile.provider == .codex, payload.kind == .browser else { throw CloudSessionError.invalidPayload }
        let payload = try payload.validated()
        try payload.identity.validateBindings(of: profile)
        let bytes = try CloudJournalCoding.encode(Entry(profileID: profile.id, storeID: profile.webDataStoreID,
            payload: payload, chromeSeedPending: chromeSeedPending))
        guard bytes.count <= CloudSyncJournal.maximumAssetBytes else { throw CloudJournalError.tooLarge }
        let root = try CloudPrivateFiles.openRoot(directory, io: .init())
        defer { close(root) }
        try CloudPrivateFiles.replace(url(profile).lastPathComponent, bytes: bytes, in: root, io: .init())
    }
    func load(for profile: PlusProfile) throws -> Entry? {
        let root: Int32
        do { root = try CloudPrivateFiles.openRoot(directory, io: .init(), create: false) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        defer { close(root) }
        let name = url(profile).lastPathComponent
        guard let bytes = try CloudPrivateFiles.read(name, in: root, limit: CloudSyncJournal.maximumAssetBytes) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: bytes)
        guard entry.profileID == profile.id, entry.storeID == profile.webDataStoreID, entry.payload.kind == .browser else { throw CloudSessionError.invalidPayload }
        _ = try entry.payload.validated()
        try entry.payload.identity.validateBindings(of: profile)
        try CloudPrivateFiles.synchronize(name, in: root)
        return entry
    }
    func remove(for profile: PlusProfile) throws {
        let root: Int32
        do { root = try CloudPrivateFiles.openRoot(directory, io: .init(), create: false) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        defer { close(root) }
        try CloudPrivateFiles.remove(url(profile).lastPathComponent, in: root)
    }
    private func url(_ profile: PlusProfile) -> URL { directory.appendingPathComponent("\(profile.id.uuidString).\(profile.webDataStoreID.uuidString).json") }
}
