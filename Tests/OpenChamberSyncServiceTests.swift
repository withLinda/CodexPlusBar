import Foundation
import Testing
@testable import CodexPlusBar

struct OpenChamberSyncServiceTests {
    @Test func restoreDoesNotActivateRetainedAccount() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let a = try nativeCredential("alpha", active: true), b = try nativeCredential("beta")
        try fixture.snapshots.saveNative(b, identity: b.openAIIdentity())
        let client = SyncTestClient([a])
        let result = try await fixture.service(client).reconcile(catalog: fixture.catalog([a, b]), isCurrent: { _ in true })
        #expect(result.matchedCount == 2)
        let entries = await client.entries
        #expect(entries.filter(\.active).map(\.id) == [a.id])
        #expect(entries.count == 2)
    }

    @Test func runningSessionsDeferActiveRemoval() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let a = try nativeCredential("alpha"), old = try nativeCredential("old", active: true)
        let client = SyncTestClient([a, old], running: true)
        let result = try await fixture.service(client).reconcile(catalog: fixture.catalog([a]), isCurrent: { _ in true })
        #expect(result.deferredActiveRemoval)
        #expect(await client.entries.count == 2)
    }

    @Test func idleActivatesReplacementBeforeDeletingOldAccount() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let a = try nativeCredential("alpha"), old = try nativeCredential("old", active: true)
        let client = SyncTestClient([a, old])
        _ = try await fixture.service(client).reconcile(catalog: fixture.catalog([a]), isCurrent: { _ in true })
        #expect(await client.operations == ["activate:cred_alpha", "remove:cred_old"])
        #expect(await client.entries.map(\.id) == [a.id])
    }

    @Test func noDesiredCredentialRemovesOldAccountOnlyWhenIdle() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let old = try nativeCredential("old", active: true)
        let client = SyncTestClient([old])
        _ = try await fixture.service(client).reconcile(catalog: fixture.catalog([]), isCurrent: { _ in true })
        #expect(await client.entries.isEmpty)
    }

    @Test func catalogChangeStopsFurtherMutations() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let old = try nativeCredential("old")
        let client = SyncTestClient([old])
        await #expect(throws: (any Error).self) {
            try await fixture.service(client).reconcile(catalog: fixture.catalog([]), isCurrent: { _ in false })
        }
        #expect(await client.operations.isEmpty)
    }

    @Test func committedCreateLostResponseDoesNotDuplicateOnRetry() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let b = try nativeCredential("beta")
        try fixture.snapshots.saveNative(b, identity: b.openAIIdentity())
        let client = SyncTestClient([], loseCreateResponse: true)
        let catalog = try fixture.catalog([b])
        _ = try? await fixture.service(client).reconcile(catalog: catalog, isCurrent: { _ in true })
        let result = try await fixture.service(client).reconcile(catalog: catalog, isCurrent: { _ in true })
        #expect(result.matchedCount == 1)
        #expect(await client.entries.count == 1)
    }

    @Test func committedDeleteLostResponseConverges() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let client = SyncTestClient([try nativeCredential("old")], loseDeleteResponse: true)
        let catalog = try fixture.catalog([])
        _ = try? await fixture.service(client).reconcile(catalog: catalog, isCurrent: { _ in true })
        let result = try await fixture.service(client).reconcile(catalog: catalog, isCurrent: { _ in true })
        #expect(result.matchedCount == 0)
        #expect(await client.entries.isEmpty)
    }

    @Test func nativeRotationNeverOverwrittenBySnapshot() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let old = try nativeCredential("alpha")
        try fixture.snapshots.saveNative(old, identity: old.openAIIdentity())
        var fresh = old; fresh.value.fields["refresh"] = .string("fresh")
        let client = SyncTestClient([fresh])
        _ = try await fixture.service(client).reconcile(catalog: fixture.catalog([old]), isCurrent: { _ in true })
        #expect(await client.operations.isEmpty)
        #expect(try fixture.snapshots.loadNativeValue(identity: old.openAIIdentity()) == fresh.value)
    }

    @Test func manualSaveAndSyncCannotOverlap() async throws {
        let gate = OpenCodeOperationGate(), barrier = SyncBarrier()
        let first = Task { try await gate.withOperation { await barrier.wait(); return 1 } }
        await barrier.started()
        await #expect(throws: OpenCodeOpenAIAuthError.busy) { try await gate.withOperation { 2 } }
        await barrier.release()
        #expect(try await first.value == 1)
        #expect(try await gate.withOperation { 3 } == 3)
    }

    @Test func cancelAfterRequestStopsNextWrite() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let barrier = SyncBarrier()
        let client = SyncTestClient([try nativeCredential("old"), try nativeCredential("other")], removalBarrier: barrier)
        let service = fixture.service(client), catalog = try fixture.catalog([])
        let task = Task { try await service.reconcile(catalog: catalog, isCurrent: { _ in true }) }
        await barrier.started(); task.cancel(); await barrier.release()
        _ = try? await task.value
        #expect(await client.operations.count == 1)
        #expect(await client.entries.count == 1)
    }

    @Test func newlyObservedLoginSurvivesUntilSavedOrGraceExpires() async throws {
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let client = SyncTestClient([])
        _ = try await fixture.service(client).reconcile(catalog: fixture.catalog([]), isCurrent: { _ in true })
        let entry = try nativeCredential("new")
        await client.append(entry)
        let pending = try await fixture.service(client).reconcile(catalog: fixture.catalog([]), isCurrent: { _ in true })
        #expect(pending.pendingCredentialCount == 1)
        let saved = try await fixture.service(client).reconcile(catalog: fixture.catalog([entry]), isCurrent: { _ in true })
        #expect(saved.pendingCredentialCount == 0)
        #expect(saved.matchedCount == 1)
        #expect(await client.entries.count == 1)
    }
}

struct SyncServiceFixture {
    let home: URL
    let snapshots: OpenCodeSignInSnapshotStore
    let state: OpenChamberSyncStateStore
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        snapshots = OpenCodeSignInSnapshotStore(homeDirectory: home)
        state = OpenChamberSyncStateStore(fileURL: home.appendingPathComponent("sync.json"))
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
    func catalog(_ entries: [OpenCodeStoredCredential]) throws -> OpenChamberSyncCatalog {
        .init(generation: 1, profiles: try entries.enumerated().map { index, entry in var p = try syncProfile(entry); p.sortOrder = index; return p }, isTrusted: true)
    }
    func service(_ client: SyncTestClient) -> OpenChamberSyncService {
        OpenChamberSyncService(resolveClient: { client }, gate: OpenCodeOperationGate(), snapshots: snapshots, stateStore: state, verifier: SyncTestVerifier())
    }
}

struct SyncTestVerifier: OpenCodeOpenAICredentialVerifying {
    func verify(_ auth: OpenCodeOpenAIAuth) async throws { _ = try auth.identity() }
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth { auth }
}

actor SyncTestClient: OpenCodeCredentialServing {
    var entries: [OpenCodeStoredCredential]
    var operations: [String] = []
    let running: Bool
    var loseCreateResponse: Bool
    var loseDeleteResponse: Bool
    let removalBarrier: SyncBarrier?
    init(_ entries: [OpenCodeStoredCredential], running: Bool = false, loseCreateResponse: Bool = false, loseDeleteResponse: Bool = false, removalBarrier: SyncBarrier? = nil) {
        self.entries = entries; self.running = running; self.loseCreateResponse = loseCreateResponse; self.loseDeleteResponse = loseDeleteResponse; self.removalBarrier = removalBarrier
    }
    func append(_ entry: OpenCodeStoredCredential) { entries.append(entry) }
    func inventory() -> OpenCodeCredentialInventory { .init(entries: entries, connectionIDs: Set(entries.filter { $0.integrationID == "openai" }.map(\.id))) }
    func create(id: String, label: String, value: OpenCodeCredentialValue, activate: Bool) throws -> OpenCodeStoredCredential {
        let entry = OpenCodeStoredCredential(id: id, integrationID: "openai", label: label, active: activate || !entries.contains(where: { $0.active }), value: value)
        entries.append(entry); operations.append("create:" + id)
        if loseCreateResponse { loseCreateResponse = false; throw URLError(.timedOut) }
        return entry
    }
    func rename(id: String, label: String) { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].label = label }; operations.append("rename:" + id) }
    func activate(id: String) { for i in entries.indices { entries[i].active = entries[i].id == id }; operations.append("activate:" + id) }
    func remove(id: String) async throws {
        entries.removeAll { $0.id == id }; operations.append("remove:" + id)
        if let removalBarrier { await removalBarrier.wait() }
        if loseDeleteResponse { loseDeleteResponse = false; throw URLError(.timedOut) }
    }
    func hasRunningSessions() -> Bool { running }
}

actor SyncBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; startedContinuation?.resume(); startedContinuation = nil } }
    func started() async { if continuation == nil { await withCheckedContinuation { startedContinuation = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}
