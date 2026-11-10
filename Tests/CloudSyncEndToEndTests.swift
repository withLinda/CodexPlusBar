import CloudKit
import Foundation
import Testing
@testable import CodexPlusBar

@MainActor struct CloudSyncEndToEndTests {
    @Test func receivedSavedSessionIsSyncedWhileItWaitsForExplicitImport() async throws {
        let server = try ReplicaCloud(); defer { server.clean() }
        let a = try Replica(server: server), b = try Replica(server: server)
        defer { a.clean(); b.clean() }
        let login = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        a.session = .desktop(signIn: login, consumed: [])
        await a.keys.deliver(b.key); await b.keys.deliver(a.key)
        await a.start(); await b.start(); await a.sync(); await b.sync()
        #expect(try await b.coordinator.sessionSummaries(for: a.original.id).count == 1)
        #expect(a.coordinator.status == .upToDate)
        #expect(b.coordinator.status == .upToDate)
        #expect(!FileManager.default.fileExists(atPath: b.native.vault.url(for: login.identity).path))
        #expect(!FileManager.default.fileExists(atPath: b.native.authURL.path))
        await a.stop(); await b.stop()
    }

    @Test func fortyFiveAndThirtyThreeOverlappingProfilesTransferAllSessionsAcrossOverlappingSendsAndRestart() async throws {
        let server = try ReplicaCloud(); defer { server.clean() }
        let rows = (0..<45).map { index in
            var row = CodexSignInFixture.profile(); row.label = "Account \(index)"; row.sortOrder = index
            return row
        }
        let smaller = rows.prefix(33).map { row in
            PlusProfile(id: row.id, label: row.label, emailLink: nil, detectedNote: nil,
                webDataStoreID: UUID(), sortOrder: row.sortOrder, createdAt: row.createdAt,
                lastRefreshAt: nil, lastKnownState: .needsLogin)
        }
        let a = try Replica(server: server, initialProfiles: rows)
        let b = try Replica(server: server, initialProfiles: smaller)
        defer { a.clean(); b.clean() }
        for (index, row) in rows.enumerated() {
            let login = try CodexSignIn(data: CodexSignInFixture.data(account: "account-\(index)", refresh: UUID().uuidString))
            var payloads: [CloudSessionPayload] = [
                .desktop(signIn: login, consumed: []),
                .openChamber(value: .legacy(try login.openChamberAuth()), consumed: [])
            ]
            if index < 32 {
                payloads.append(.browser(cookies: [.init(name: "__Secure-next-auth.session-token", value: UUID().uuidString,
                    domain: "chatgpt.com", path: "/", secure: true, httpOnly: true, expires: nil, sameSite: nil)],
                    identity: .init(accountID: "account-\(index)", userID: "user"), accessToken: login.accessToken))
            }
            a.sessions[row.id] = payloads
        }
        await a.keys.deliver(b.key); await b.keys.deliver(a.key)
        await a.driver.overlapEmptySends(); await b.driver.overlapEmptySends()
        await a.start(); await b.start(); await a.sync(); await b.sync()
        #expect(try a.journal.catalogState().sessions.count == 122)
        #expect(try Set(a.rows().map(\.id)) == Set(rows.map(\.id)))
        #expect(try Set(b.rows().map(\.id)) == Set(rows.map(\.id)))
        for row in smaller { #expect(try b.rows().first { $0.id == row.id }?.webDataStoreID == row.webDataStoreID) }
        var imported = 0
        for row in try b.rows() { imported += try await b.coordinator.sessionSummaries(for: row.id).count }
        #expect(imported == 122)
        #expect(a.coordinator.status == .upToDate && b.coordinator.status == .upToDate)
        #expect(try a.journal.catalogState().dirtyGenerations.isEmpty)
        #expect(try b.journal.catalogState().dirtyGenerations.isEmpty)
        // Rebuild controllers, transport and coordinator from disk, then confirm the
        // retained captures do not create new generations or duplicate cloud records.
        let writes = await server.writes
        await a.restart(); await b.restart(); await a.sync(); await b.sync()
        #expect(a.coordinator.status == .upToDate && b.coordinator.status == .upToDate)
        #expect(await server.writes == writes)
        #expect(try b.rows().count == 45)
        #expect(!FileManager.default.fileExists(atPath: b.native.authURL.path))
        await a.stop(); await b.stop()
    }

    @Test func twoEncryptedReplicasMergeOfflineEditsAndNeverResurrectDeletedRows() async throws {
        let server = try ReplicaCloud(); defer { server.clean() }
        let a = try Replica(server: server), b = try Replica(server: server)
        defer { a.clean(); b.clean() }
        await a.keys.deliver(b.key); await b.keys.deliver(a.key)
        await a.start(); await b.start(); await a.sync()
        let id = a.original.id
        let bStoreID = try #require(b.rows().first { $0.id == id }?.webDataStoreID)
        #expect(bStoreID != a.original.webDataStoreID)
        let selected = b.profiles.selectedProfileID
        await a.driver.setOnline(false); await b.driver.setOnline(false)
        try a.edit(id) { $0.notes = "edited offline on A"; $0.password = ""; $0.label = "conflict A" }
        try b.edit(id) { $0.phoneNumber = "+1 555 0100"; $0.label = "conflict B" }
        await a.sync(); await b.sync()
        #expect(a.coordinator.status != .upToDate && b.coordinator.status != .upToDate)
        await a.driver.setOnline(true); await b.driver.setOnline(true)
        await a.sync(); await b.sync(); await a.sync(); await b.sync()
        let left = try #require(a.rows().first { $0.id == id })
        let right = try #require(b.rows().first { $0.id == id })
        #expect(left.label == right.label && ["conflict A", "conflict B"].contains(left.label))
        #expect(left.notes == "edited offline on A" && right.notes == left.notes)
        #expect(left.phoneNumber == "+1 555 0100" && right.phoneNumber == left.phoneNumber)
        #expect((left.password ?? "").isEmpty && (right.password ?? "").isEmpty)
        #expect(right.webDataStoreID == bStoreID && b.profiles.selectedProfileID == selected)

        b.profiles.setCloudDraftOwner(id)
        let draftBase = PlusProfileDetailsDraft(profile: right)
        var unsaved = draftBase; unsaved.phoneNumber = "+1 555 0199"
        try a.edit(id) { $0.notes = "remote edit while B has an unsaved draft" }
        await a.sync(); await b.sync()
        #expect(b.profiles.updateDetails(for: id, draft: unsaved, base: draftBase))
        b.profiles.setCloudDraftOwner(nil)
        await b.sync()
        #expect(try b.rows().first { $0.id == id }?.notes == "remote edit while B has an unsaved draft")
        #expect(try b.rows().first { $0.id == id }?.phoneNumber == "+1 555 0199")

        a.profiles.addProfile(label: "newly created on A")
        await a.sync(); await b.sync()
        #expect(try b.rows().contains { $0.label == "newly created on A" })
        await a.coordinator.setEnabled(false)
        let reordered = try a.rows().reversed().enumerated().map { index, profile in
            var profile = profile; profile.sortOrder = index; return profile
        }
        try a.store.saveProfiles(reordered)
        await a.restart(); await a.coordinator.setEnabled(true); await b.sync()
        #expect(try b.rows().sorted { $0.sortOrder < $1.sortOrder }.map(\.id) == reordered.map(\.id))

        // A's next save reaches the server but its acknowledgement is lost.
        await a.driver.dropNextAcknowledgement()
        try a.edit(id) { $0.notes = "survives unacknowledged send" }
        await a.sync()
        await a.restart(); await a.sync(); await b.sync()
        #expect(try b.rows().first { $0.id == id }?.notes == "survives unacknowledged send")

        await b.driver.setOnline(false)
        await a.profiles.removeProfile(id: id); await a.sync()
        try b.edit(id) { $0.notes = "stale offline edit cannot resurrect" }
        await b.sync(); await b.driver.setOnline(true)
        await b.sync(); await a.sync()
        #expect(try !a.rows().contains { $0.id == id })
        #expect(try !b.rows().contains { $0.id == id })
        #expect(try a.journal.catalogState().profiles[CloudJournalState.profileRecordName(id)]?.tombstone != nil)
        let writes = await server.writes
        await a.sync(); await b.sync()
        #expect(await server.writes == writes)
        await a.stop(); await b.stop()
    }

    @Test func delayedKeysRequireExplicitSessionImportAndRestoreRequiresReenable() async throws {
        let server = try ReplicaCloud(); defer { server.clean() }
        let a = try Replica(server: server), b = try Replica(server: server)
        defer { a.clean(); b.clean() }
        let login = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        a.session = .desktop(signIn: login, consumed: [])
        await a.start(); await b.start()
        #expect(try !b.rows().contains { $0.id == a.original.id })
        #expect(b.coordinator.status != .upToDate)
        await b.keys.deliver(a.key); await a.keys.deliver(b.key)
        await b.sync(); await a.sync(); await b.sync()
        let summary = try #require(try await b.coordinator.sessionSummaries(for: a.original.id).first)
        #expect(summary.sourceName == "Synthetic source Mac")
        #expect(!FileManager.default.fileExists(atPath: b.native.vault.url(for: login.identity).path))
        try await b.coordinator.adoptSession(.init(profileID: a.original.id, recordName: summary.recordName, sourceRevision: summary.revision))
        #expect(try b.native.vault.load(login.identity) == login)
        #expect(!FileManager.default.fileExists(atPath: b.native.authURL.path))
        #expect(try b.journal.catalogState().sessions.isEmpty)

        try await b.coordinator.pauseForTransfer(restoring: true)
        try b.coordinator.markRestoreCommitAttempt()
        await b.coordinator.resumeAfterTransfer(restored: true)
        #expect(!b.coordinator.isEnabled && b.coordinator.status == .paused)
        await b.restart()
        #expect(!b.coordinator.isEnabled && b.coordinator.status == .paused)
        await b.coordinator.setEnabled(true); await b.sync()
        #expect(b.coordinator.isEnabled)
        #expect(try Set(b.rows().map(\.id)) == Set(a.rows().map(\.id)))
        let previous = b.owner
        b.owner = .init(container: previous.container, environment: previous.environment, userRecordName: "replacement")
        await b.sync()
        #expect(!b.coordinator.isEnabled && b.coordinator.status == .needsConsent)
        #expect(try b.native.vault.load(login.identity) == login)
        await a.stop(); await b.stop()
    }
}

/// Replaces only the remote CloudKit service; payload encoding, encryption, transport,
/// journals, catalog application, and destination native vault are production code.
private actor ReplicaCloud {
    nonisolated let root: URL
    private var records: [String: CKRecord] = [:]
    private var deletions: Set<CKRecord.ID> = []
    private(set) var writes = 0
    private(set) var zoneExists = false
    init() throws {
        root = try CodexSignInFixture.directory()
    }
    nonisolated func clean() { try? FileManager.default.removeItem(at: root) }
    func createZone() { zoneExists = true }
    func fetch() -> ([CKRecord], [CKRecord.ID]) { (Array(records.values), Array(deletions)) }
    func save(_ incoming: [CKRecord], deleting: [CKRecord.ID]) throws -> [CKRecord] {
        var saved: [CKRecord] = []
        for record in incoming {
            let copy = record.copy() as! CKRecord
            let asset = try #require((record["payload"] as? CKAsset)?.fileURL)
            let destination = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: asset, to: destination)
            copy["payload"] = CKAsset(fileURL: destination)
            records[copy.recordID.recordName] = copy; saved.append(copy); writes += 1
        }
        for id in deleting { records.removeValue(forKey: id.recordName); deletions.insert(id); writes += 1 }
        return saved
    }
}

private actor ReplicaDriver: CloudEngineDriving {
    let server: ReplicaCloud
    private var callbacks: CloudEngineCallbacks?
    private var pending: [CKSyncEngine.PendingRecordZoneChange] = []
    private var online = true
    private var omitAcknowledgement = false
    private var zoneSavePending = false
    private var overlap = false
    init(server: ReplicaCloud) { self.server = server }
    func setOnline(_ value: Bool) { online = value }
    func dropNextAcknowledgement() { omitAcknowledgement = true }
    func overlapEmptySends() { overlap = true }
    func start(owner: CloudOwner, state: Data?, callbacks: CloudEngineCallbacks) { self.callbacks = callbacks }
    func setPending(_ changes: [CKSyncEngine.PendingRecordZoneChange]) { pending = changes }
    // Like CKSyncEngine.State.add, this queues rather than performs the save.
    func createZone() { zoneSavePending = true }
    func fetchChanges() async throws {
        guard online else { throw CKError(.networkUnavailable) }
        guard await server.zoneExists else { throw CKError(.zoneNotFound) }
        let (records, deleted) = await server.fetch()
        await callbacks?.event(.fetchStarted)
        await callbacks?.event(.fetched(records: records, deletions: deleted))
        await callbacks?.event(.zoneFetched(error: nil))
        await callbacks?.event(.fetchFinished)
    }
    func sendChanges() async throws {
        guard online else { throw CKError(.networkUnavailable) }
        guard let callbacks else { return }
        await callbacks.event(.sendStarted)
        if zoneSavePending {
            await server.createZone(); zoneSavePending = false
            await callbacks.event(.zoneSaved(error: nil))
        }
        guard let batch = await callbacks.nextBatch(.all, pending) else {
            await callbacks.event(.sendFinished); return
        }
        if overlap {
            await callbacks.event(.sendStarted)
            await callbacks.event(.sendFinished)
        }
        let saved = try await server.save(batch.recordsToSave, deleting: batch.recordIDsToDelete)
        if omitAcknowledgement { omitAcknowledgement = false; await callbacks.event(.sendFinished); return }
        await callbacks.event(.sent(saved: saved, failed: [], deleted: batch.recordIDsToDelete, failedDeletes: [:]))
        await callbacks.event(.sendFinished)
    }
    func cancelOperations() { callbacks = nil }
}

@MainActor private final class Replica {
    let root: URL
    let original: PlusProfile
    let store: ProfileCatalogStore
    let preferences: CloudSyncPreferencesStore
    let journal: CloudSyncJournal
    let key: CloudEncryptionKey
    let keys: CloudTransportKeys
    let driver: ReplicaDriver
    let native: NativeSwitchFixture
    let defaults: UserDefaults
    let suite = "CloudEndToEnd.\(UUID())"
    var owner = CloudOwner(container: CloudSyncAvailability.containerIdentifier, environment: .development, userRecordName: "replica-owner")
    var session: CloudSessionPayload?
    var sessions: [UUID: [CloudSessionPayload]] = [:]
    var profiles: PlusProfileController!
    var coordinator: CloudSyncCoordinator!
    init(server: ReplicaCloud, initialProfiles: [PlusProfile]? = nil) throws {
        root = try CodexSignInFixture.directory()
        native = try NativeSwitchFixture()
        original = initialProfiles?.first ?? CodexSignInFixture.profile()
        store = .init(fileURL: root.appendingPathComponent("accounts/profiles.json"))
        try store.saveProfiles(initialProfiles ?? [original])
        preferences = .init(root: root.appendingPathComponent("cloud"))
        journal = .init(root: root.appendingPathComponent("cloud"), owner: owner)
        key = try CloudCryptoFixture.key(); keys = CloudTransportKeys(key)
        driver = ReplicaDriver(server: server)
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: OpenChamberSyncPreference.enabledKey)
        assemble()
    }
    func assemble() {
        profiles = .init(catalogStore: store, dataService: ReplicaDataService(), accountSwitchService: native.service,
                         syncDefaults: defaults, autoStart: false)
        coordinator = .init(profiles: profiles, preferences: preferences, availability: { .development },
            identity: { [unowned self] _ in self.owner },
            snapshots: .init(providers: [CloudSessionKind.desktop, .browser, .openChamber].map { kind in
                { [unowned self] profile in
                    if let payload = self.sessions[profile.id]?.first(where: { $0.kind == kind }) { return payload }
                    return profile.id == self.original.id && self.session?.kind == kind ? self.session : nil
                }
            }, revision: { 0 }),
            sourceName: { "Synthetic source Mac" },
            nativeAdoption: { [unowned self] in .init(authorization: $0, desktop: self.native.service) },
            makeSessionInbox: { [unowned self] in .init(journal: $0, keys: self.keys) },
            makeTransport: { [unowned self] journal in
                CloudKitAccountSync(journal: journal, keys: self.keys, assets: .init(root: self.root.appendingPathComponent("assets")),
                    makeDriver: { [driver = self.driver] in driver })
            })
    }
    func start() async { await coordinator.start(); await coordinator.setEnabled(true) }
    func sync() async { await coordinator.syncNow() }
    func stop() async { await coordinator.stop(); profiles.stopBackgroundTasks() }
    func restart() async { await stop(); assemble(); await coordinator.start() }
    func rows() throws -> [PlusProfile] { try store.loadProfiles() }
    func edit(_ id: UUID, _ change: (inout PlusProfileDetailsDraft) -> Void) throws {
        let row = try #require(try rows().first { $0.id == id })
        var draft = PlusProfileDetailsDraft(profile: row); change(&draft)
        #expect(profiles.updateDetails(for: id, draft: draft, base: .init(profile: row)))
    }
    func clean() {
        profiles.stopBackgroundTasks(); defaults.removePersistentDomain(forName: suite); native.cleanUp()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class ReplicaDataService: PlusProfileDataServing {
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult { throw ChatGPTAPIError.unauthorized }
    func openChromeAccountPage(for profile: PlusProfile) async throws {}
    func openChromeSignIn(for profile: PlusProfile) async throws {}
    func openChromePasskeySetup(for profile: PlusProfile) async throws {}
    func syncChromeSession(for profile: PlusProfile) async throws {}
    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool { false }
    func closeChromeSignIn(for profile: PlusProfile) async {}
    func clearSession(for profile: PlusProfile) async throws {}
    func removeProfileData(for profile: PlusProfile) async throws {}
}
