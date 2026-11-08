import Foundation
import Testing
@testable import CodexPlusBar

struct OpenChamberSignInCheckTests {
    @Test func selectingExistingDuplicateDuringRefreshedVerificationIsInconclusive() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let expired = try fixture.auth("duplicate", expires: 0), fresh = try fixture.auth("duplicate", refresh: "fresh")
        let entry = OpenCodeStoredCredential(id: "cred_expired", integrationID: "openai", label: "Expired", active: false, value: .legacy(expired))
        let duplicate = OpenCodeStoredCredential(id: "cred_000_duplicate", integrationID: "openai", label: "Duplicate", active: false, value: .legacy(expired))
        let selected = try nativeCredential("other", active: true)
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: fixture.home)
        try snapshots.saveNative(entry, identity: entry.openAIIdentity())
        let client = SyncTestClient([selected, entry, duplicate]), barrier = SyncBarrier(), output = CheckOutput()
        let service = OpenChamberSignInCheckService(resolveClient: { client }, snapshots: snapshots,
            verifier: WaitingCheckVerifier(fresh: fresh, barrier: barrier), gate: .init(), now: { OpenCodeAuthFixture.now })
        let task = Task { try await service.check(profiles: [syncProfile(entry)]) { await output.append($0) } }
        await barrier.started()
        await client.activate(id: duplicate.id)
        await barrier.release(); try await task.value
        #expect(await output.values.first?.record.outcome == .unchecked)
        #expect(await client.inventory().openAI.first(where: \.active)?.id == duplicate.id)
        #expect(try snapshots.resolved(expired) == fresh)
    }

    @Test(arguments: [false, true])
    func newNativeSignInDuringRejectionInvalidatesOldEvidence(snapshotOnly: Bool) async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let old = try nativeCredential("old"), other = try nativeCredential("other", active: true)
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: fixture.home)
        try snapshots.saveNative(old, identity: old.openAIIdentity())
        let client = SyncTestClient(snapshotOnly ? [other] : [other, old])
        let barrier = SyncBarrier(), output = CheckOutput()
        let service = OpenChamberSignInCheckService(resolveClient: { client }, snapshots: snapshots,
            verifier: RejectingCheckVerifier(barrier: barrier), gate: .init())
        let task = Task { try await service.check(profiles: [syncProfile(old)]) { await output.append($0) } }
        await barrier.started()
        var replacement = old.value; replacement.fields["refresh"] = .string("new-login")
        _ = try await client.create(id: "cred_new_login", label: old.label, value: replacement, activate: false)
        await barrier.release(); try await task.value
        #expect(await output.values.first?.record.outcome == .unchecked)
        #expect(await client.inventory().openAI.first(where: \.active) == other)
    }

    @Test(arguments: ["metadata", "methodID"])
    func unreadableBoundNativeCredentialIsNotConfirmedMissing(field: String) async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        var entry = try nativeCredential("broken")
        let profile = try syncProfile(entry)
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: fixture.home)
        try snapshots.saveBinding(id: entry.id, identity: entry.openAIIdentity())
        entry.value.fields[field] = .string("unreadable-or-unsupported")
        let client = SyncTestClient([entry]), output = CheckOutput()
        let service = OpenChamberSignInCheckService(resolveClient: { client }, snapshots: snapshots,
            verifier: SyncTestVerifier(), gate: .init())
        try await service.check(profiles: [profile]) { await output.append($0) }
        #expect(await output.values.first?.record.outcome == .unchecked)
        #expect(await client.operations.isEmpty)
    }

    @Test(arguments: ["unknown-outcome", "invalid-date"])
    func invalidAdvisoryCheckDoesNotDiscardProfile(problem: String) throws {
        let profile = try syncProfile(nativeCredential("one"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json["openChamberSignInCheck"] = ["identityKey": profile.openCodeOpenAIAccount!.storageKey,
            "outcome": problem == "unknown-outcome" ? "future-status" : "verified",
            "checkedAt": problem == "invalid-date" ? "not-a-date" : 123] as [String: Any]
        let decoded = try JSONDecoder().decode(PlusProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == profile)
        #expect(decoded.openChamberSignInCheck == nil)
    }

    @Test func mixedResultsDoNotConfuseRejectionWithNetworkFailure() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let entries = try ["good", "revoked", "offline"].map { name in
            OpenCodeStoredCredential(id: "cred_" + name, integrationID: "openai", label: name, active: name == "good",
                                     value: .legacy(try fixture.auth(name)))
        }
        var profiles = try entries.map(syncProfile)
        profiles.append(fixture.profile("missing"))
        var claude = fixture.profile("claude"); claude.provider = .claude; profiles.append(claude)
        let client = SyncTestClient(entries), output = CheckOutput()
        let verifier = OpenCodeOpenAICredentialVerifier(request: { request in
            if request.url?.path == "/oauth/token" {
                return (Data(#"{"error":"invalid_grant"}"#.utf8), nativeResponse(request, 400))
            }
            switch request.value(forHTTPHeaderField: "ChatGPT-Account-ID") {
            case "account-revoked": return (Data(), nativeResponse(request, 401))
            case "account-offline": throw URLError(.notConnectedToInternet)
            default: return (Data(#"{"rate_limit":{}}"#.utf8), nativeResponse(request, 200))
            }
        })
        let service = OpenChamberSignInCheckService(resolveClient: { client },
            snapshots: .init(homeDirectory: fixture.home), verifier: verifier, gate: OpenCodeOperationGate(), now: { OpenCodeAuthFixture.now })
        try await service.check(profiles: profiles) { await output.append($0) }
        #expect(await output.values.map(\.record.outcome) == [.verified, .needsSignIn, .unchecked, .needsSignIn])
        #expect(await client.entries == entries)
    }

    @Test func rotatedInactiveCredentialIsDurableWithoutSelectingItsAccount() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let original = try nativeCredential("original", active: true)
        let expired = try fixture.auth("expired", expires: 0)
        let fresh = try fixture.auth("expired", refresh: "fresh")
        var value = OpenCodeCredentialValue.legacy(expired)
        value.fields["extra"] = .string("keep")
        let entry = OpenCodeStoredCredential(id: "cred_expired", integrationID: "openai", label: "Expired", active: false, value: value)
        let client = SyncTestClient([original, entry]), output = CheckOutput()
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: fixture.home)
        let service = OpenChamberSignInCheckService(resolveClient: { client }, snapshots: snapshots,
            verifier: CheckRefreshVerifier(fresh: fresh, failure: .unavailable), gate: OpenCodeOperationGate(), now: { OpenCodeAuthFixture.now })
        try await service.check(profiles: [syncProfile(entry)]) { await output.append($0) }
        #expect(await output.values.first?.record.outcome == .unchecked)
        #expect(try snapshots.resolved(expired) == fresh)
        #expect(try snapshots.loadNativeValue(identity: fresh.identity())?.fields["extra"] == .string("keep"))
        let inventory = await client.inventory()
        #expect(inventory.openAI.first(where: \.active) == original)
        #expect(try inventory.oauth.contains { try $0.value.auth() == fresh })
        #expect(!inventory.entries.contains { $0.id == entry.id })
    }

    @Test func duplicateProfilesShareOneRefreshAndCancellationKeepsRotation() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let expired = try fixture.auth("expired", expires: 0), fresh = try fixture.auth("expired", refresh: "fresh")
        let entry = OpenCodeStoredCredential(id: "cred_expired", integrationID: "openai", label: "Expired", active: false, value: .legacy(expired))
        let original = try nativeCredential("original", active: true)
        let client = SyncTestClient([original, entry], loseCreateResponse: true)
        let verifier = CountingCheckVerifier(fresh: fresh), output = CheckOutput()
        let service = OpenChamberSignInCheckService(resolveClient: { client }, snapshots: .init(homeDirectory: fixture.home),
            verifier: verifier, gate: OpenCodeOperationGate(), now: { OpenCodeAuthFixture.now })
        try await service.check(profiles: [syncProfile(entry), syncProfile(entry)]) { await output.append($0) }
        #expect(await output.values.map(\.record.outcome) == [.verified, .verified])
        #expect(await verifier.refreshes == 1)
        #expect(await client.inventory().openAI.first(where: \.active) == original)
    }

    @Test func changedSelectionDuringRefreshIsNotOverwrittenOrMarkedRevoked() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let expired = try fixture.auth("expired", expires: 0), fresh = try fixture.auth("expired", refresh: "fresh")
        let entry = OpenCodeStoredCredential(id: "cred_expired", integrationID: "openai", label: "Expired", active: true, value: .legacy(expired))
        let other = try nativeCredential("other")
        let client = SyncTestClient([entry, other]), barrier = SyncBarrier(), output = CheckOutput()
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: fixture.home)
        let verifier = CountingCheckVerifier(fresh: fresh, barrier: barrier)
        let service = OpenChamberSignInCheckService(resolveClient: { client }, snapshots: snapshots,
            verifier: verifier, gate: OpenCodeOperationGate(), now: { OpenCodeAuthFixture.now })
        let task = Task { try await service.check(profiles: [syncProfile(entry)]) { await output.append($0) } }
        await barrier.started()
        await client.activate(id: other.id)
        await barrier.release()
        try await task.value
        #expect(await output.values.first?.record.outcome == .unchecked)
        #expect(await client.inventory().openAI.first(where: \.active)?.id == other.id)
        #expect(try snapshots.resolved(expired) == fresh)
    }

    @Test func cancelAfterRefreshResponsePreservesFreshNativeValueBeforeStopping() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let expired = try fixture.auth("expired", expires: 0), fresh = try fixture.auth("expired", refresh: "fresh")
        let entry = OpenCodeStoredCredential(id: "cred_expired", integrationID: "openai", label: "Expired", active: false, value: .legacy(expired))
        let original = try nativeCredential("original", active: true)
        let client = SyncTestClient([original, entry]), barrier = SyncBarrier(), output = CheckOutput()
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: fixture.home)
        let service = OpenChamberSignInCheckService(resolveClient: { client }, snapshots: snapshots,
            verifier: CountingCheckVerifier(fresh: fresh, barrier: barrier), gate: OpenCodeOperationGate(), now: { OpenCodeAuthFixture.now })
        let task = Task { try await service.check(profiles: [syncProfile(entry)]) { await output.append($0) } }
        await barrier.started(); task.cancel(); await barrier.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try snapshots.resolved(expired) == fresh)
        #expect(try await client.inventory().oauth.contains { try $0.value.auth() == fresh })
        #expect(await output.values.isEmpty)
        #expect(await client.inventory().openAI.first(where: \.active) == original)
    }
}

actor CheckOutput {
    var values: [OpenChamberSignInCheckUpdate] = []
    func append(_ value: OpenChamberSignInCheckUpdate) { values.append(value) }
}

struct CheckRefreshVerifier: OpenCodeOpenAICredentialVerifying {
    let fresh: OpenCodeOpenAIAuth
    var failure: OpenCodeOpenAIVerificationError?
    func verify(_ auth: OpenCodeOpenAIAuth) async throws { if let failure { throw failure } }
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth { fresh }
}

struct RejectingCheckVerifier: OpenCodeOpenAICredentialVerifying {
    let barrier: SyncBarrier
    func verify(_ auth: OpenCodeOpenAIAuth) async throws { throw OpenCodeOpenAIVerificationError.unauthorized }
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth {
        await barrier.wait()
        throw OpenCodeOpenAIVerificationError.reauthenticationRequired
    }
}

struct WaitingCheckVerifier: OpenCodeOpenAICredentialVerifying {
    let fresh: OpenCodeOpenAIAuth
    let barrier: SyncBarrier
    func verify(_ auth: OpenCodeOpenAIAuth) async throws { await barrier.wait() }
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth { fresh }
}

actor CountingCheckVerifier: OpenCodeOpenAICredentialVerifying {
    let fresh: OpenCodeOpenAIAuth
    let barrier: SyncBarrier?
    var refreshes = 0
    init(fresh: OpenCodeOpenAIAuth, barrier: SyncBarrier? = nil) { self.fresh = fresh; self.barrier = barrier }
    func verify(_ auth: OpenCodeOpenAIAuth) async throws {}
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth {
        refreshes += 1
        if let barrier { await barrier.wait() }
        return fresh
    }
}

@MainActor struct OpenChamberCheckControllerTests {
    @Test func browserClearPreservesConcurrentCheckAfterReordering() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let a = try syncProfile(nativeCredential("alpha")), b = try syncProfile(nativeCredential("beta"))
        try f.store.saveProfiles([a, b])
        let data = SyncControllerDataService(), barrier = SyncBarrier(); data.clearBarrier = barrier
        let controller = PlusProfileController(catalogStore: f.store, dataService: data,
            signInChecker: ControllerCheckService(outcome: .needsSignIn), syncDefaults: f.defaults, autoStart: false)
        let clear = Task { await controller.clearSession(for: a.id) }
        await barrier.started()
        await controller.checkAllOpenChamberSignIns()
        controller.profiles.swapAt(0, 1)
        await barrier.release(); await clear.value
        let saved = try f.store.loadProfiles()
        #expect(saved.map(\.id) == [b.id, a.id])
        #expect(saved.allSatisfy { $0.currentOpenChamberSignInCheck?.outcome == .needsSignIn })
        #expect(saved.first(where: { $0.id == a.id })?.lastKnownState == .needsLogin)
    }

    @Test func uncheckedCountIncludesNewProfilesAndGlobalErrors() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let a = try syncProfile(nativeCredential("alpha")), b = try syncProfile(nativeCredential("beta"))
        try f.store.saveProfiles([a])
        let checker = ControllerCheckService(outcome: .verified)
        let controller = PlusProfileController(catalogStore: f.store, signInChecker: checker, syncDefaults: f.defaults, autoStart: false)
        await controller.checkAllOpenChamberSignIns()
        controller.profiles.append(.init(profile: b, state: .idle, usage: nil, statusMessage: nil, isRefreshing: false))
        #expect(controller.openChamberSignInCheckMessage == "OpenChamber · 0 need sign-in · 1 not checked")
        await checker.setUnavailable()
        await controller.checkAllOpenChamberSignIns()
        #expect(controller.openChamberSignInCheckMessage?.contains("2 not checked") == true)
        #expect(controller.openChamberCheckError != nil)
    }

    @Test func rejectionPersistsAcrossReloadAndNetworkFailureUntilManualRepair() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let store = ProfileCatalogStore(fileURL: fixture.home.appendingPathComponent("profiles.json"))
        var profile = fixture.profile("one")
        profile.openCodeOpenAIAccount = try fixture.auth("one").identity()
        try store.saveProfiles([profile])
        let checker = ControllerCheckService(outcome: .needsSignIn)
        let controller = PlusProfileController(catalogStore: store, openCodeAuthService: fixture.service, signInChecker: checker, autoStart: false)
        await controller.checkAllOpenChamberSignIns()
        #expect(controller.openChamberSignInRepairCount == 1)
        #expect(controller.profiles.first?.state == .idle)
        let reloaded = PlusProfileController(catalogStore: store, openCodeAuthService: fixture.service, signInChecker: checker, autoStart: false)
        #expect(reloaded.openChamberSignInNeedsRepair(for: profile.id))
        await checker.setOutcome(.unchecked)
        await reloaded.checkAllOpenChamberSignIns()
        #expect(reloaded.openChamberSignInRepairCount == 1)
        #expect(reloaded.openChamberSignInCheckMessage?.contains("1 not checked") == true)
        try fixture.write(fixture.auth("one"))
        await reloaded.saveOpenChamberAuth(profileID: profile.id)
        #expect(reloaded.openChamberSignInRepairCount == 0)
        #expect(try store.loadProfiles().first?.openChamberSignInCheck == nil)
    }

    @Test func scanBlocksReentryAndIgnoresChangedIdentity() async throws {
        let fixture = try OpenCodeAuthFixture(); defer { fixture.remove() }
        let store = ProfileCatalogStore(fileURL: fixture.home.appendingPathComponent("profiles.json"))
        var profile = fixture.profile("one"); profile.openCodeOpenAIAccount = try fixture.auth("one").identity()
        try store.saveProfiles([profile])
        let barrier = SyncBarrier(), checker = ControllerCheckService(outcome: .needsSignIn, barrier: barrier)
        let controller = PlusProfileController(catalogStore: store, openCodeAuthService: fixture.service, signInChecker: checker, autoStart: false)
        let task = Task { await controller.checkAllOpenChamberSignIns() }
        await barrier.started()
        #expect(!controller.canCheckOpenChamberSignIns)
        await controller.checkAllOpenChamberSignIns()
        await controller.switchOpenChamberAuth(profileID: profile.id)
        #expect(controller.openChamberActionStatus == nil)
        var changed = profile; changed.openCodeOpenAIAccount = try fixture.auth("two").identity()
        controller.profiles[0] = controller.profiles[0].updating(profile: changed)
        await barrier.release(); await task.value
        #expect(controller.openChamberSignInRepairCount == 0)
        #expect(controller.profiles[0].profile.openChamberSignInCheck == nil)
        #expect(await checker.calls == 1)
    }
}

actor ControllerCheckService: OpenChamberSignInChecking {
    var outcome: OpenChamberSignInCheckOutcome
    let barrier: SyncBarrier?
    var calls = 0
    var unavailable = false
    init(outcome: OpenChamberSignInCheckOutcome, barrier: SyncBarrier? = nil) { self.outcome = outcome; self.barrier = barrier }
    func setOutcome(_ value: OpenChamberSignInCheckOutcome) { outcome = value }
    func setUnavailable() { unavailable = true }
    func check(profiles: [PlusProfile], didCheck: @escaping @Sendable (OpenChamberSignInCheckUpdate) async -> Void) async throws {
        calls += 1
        if unavailable { throw OpenCodeCredentialError.unavailable }
        if let barrier { await barrier.wait() }
        for profile in profiles {
            try Task.checkCancellation()
            await didCheck(.init(profileID: profile.id, record: .init(identityKey: profile.openCodeOpenAIAccount?.storageKey, outcome: outcome, checkedAt: .now)))
        }
    }
}
