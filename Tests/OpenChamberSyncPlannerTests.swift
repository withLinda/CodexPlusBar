import Foundation
import Testing
@testable import CodexPlusBar

struct OpenChamberSyncPlannerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func retainsActiveDuplicateThenBoundThenStableID() throws {
        let entry = try nativeCredential("alpha")
        let profile = try syncProfile(entry)
        let identity = try entry.openAIIdentity()
        let accounts = ["cred_z", "cred_a", "cred_b"].map { OpenChamberSyncAccount(id: $0, label: entry.label, active: $0 == "cred_z", identity: identity) }
        let catalog = OpenChamberSyncCatalog(generation: 1, profiles: [profile], isTrusted: true)
        let plan = try OpenChamberSyncPlanner.plan(catalog: catalog, accounts: accounts, savedBindings: [identity.storageKey: "cred_b"], state: .baseline(accounts), now: now)
        #expect(plan.bindings[profile.id] == "cred_z")
        #expect(Set(plan.removeIDs) == ["cred_a", "cred_b"])
        let inactive = accounts.map { OpenChamberSyncAccount(id: $0.id, label: $0.label, active: false, identity: $0.identity) }
        let bound = try OpenChamberSyncPlanner.plan(catalog: catalog, accounts: inactive, savedBindings: [identity.storageKey: "cred_b"], state: .baseline(inactive), now: now)
        #expect(bound.bindings[profile.id] == "cred_b")
        let stable = try OpenChamberSyncPlanner.plan(catalog: catalog, accounts: inactive, savedBindings: [:], state: .baseline(inactive), now: now)
        #expect(stable.bindings[profile.id] == "cred_a")
    }

    @Test func profileRemovalPrunesEvenWhenSnapshotStillExists() throws {
        let account = try OpenChamberSyncAccount(nativeCredential("old"))
        let plan = try OpenChamberSyncPlanner.plan(catalog: .init(generation: 2, profiles: [], isTrusted: true), accounts: [account], savedBindings: [account.identity.storageKey: account.id], state: .baseline([account]), now: now)
        #expect(plan.removeIDs == ["cred_old"])
        #expect(plan.restoreProfileIDs.isEmpty)
    }

    @Test func labelEditsDoNotChangeMembership() throws {
        let entry = try nativeCredential("alpha")
        var profile = try syncProfile(entry); profile.label = "Renamed"
        let account = try OpenChamberSyncAccount(entry)
        let plan = try OpenChamberSyncPlanner.plan(catalog: .init(generation: 1, profiles: [profile], isTrusted: true), accounts: [account], savedBindings: [:], state: .baseline([account]), now: now)
        #expect(plan.renames == ["cred_alpha": "Renamed"])
        #expect(plan.removeIDs.isEmpty)
    }

    @Test func unboundProfileNeedsManualCapture() throws {
        let entry = try nativeCredential("alpha")
        var profile = try syncProfile(entry); profile.openCodeOpenAIAccount = nil
        let account = try OpenChamberSyncAccount(entry)
        let state = OpenChamberSyncState(hasBaseline: true, seenCredentialIDs: [], pendingSince: [:]).observing(accounts: [account], now: now)
        let plan = try OpenChamberSyncPlanner.plan(catalog: .init(generation: 1, profiles: [profile], isTrusted: true), accounts: [account], savedBindings: [:], state: state, now: now)
        #expect(plan.bindings.isEmpty)
        #expect(plan.needsSignInProfileIDs == [profile.id])
        #expect(plan.removeIDs.isEmpty)
    }

    @Test func graceExpiresAtExactlyFifteenMinutes() throws {
        let account = try OpenChamberSyncAccount(nativeCredential("new"))
        let state = OpenChamberSyncState(hasBaseline: true, seenCredentialIDs: [], pendingSince: [:]).observing(accounts: [account], now: now)
        for (elapsed, removed) in [(899.0, false), (900.0, true)] {
            let plan = try OpenChamberSyncPlanner.plan(catalog: .init(generation: 1, profiles: [], isTrusted: true), accounts: [account], savedBindings: [:], state: state, now: now.addingTimeInterval(elapsed))
            #expect(plan.removeIDs.contains(account.id) == removed)
        }
    }

    @Test func untrustedCatalogCannotPrune() throws {
        #expect(throws: OpenChamberSyncError.catalogUnavailable) {
            try OpenChamberSyncPlanner.plan(catalog: .init(generation: 0, profiles: [], isTrusted: false), accounts: [], savedBindings: [:], state: .init(), now: now)
        }
    }

    @Test func duplicateProfilesShareOneCredential() throws {
        let entry = try nativeCredential("alpha"); let a = try syncProfile(entry); var b = try syncProfile(entry); b.label = "Second"; b.sortOrder = 1
        let account = try OpenChamberSyncAccount(entry)
        let plan = try OpenChamberSyncPlanner.plan(catalog: .init(generation: 1, profiles: [a, b], isTrusted: true), accounts: [account], savedBindings: [:], state: .baseline([account]), now: now)
        #expect(plan.bindings.count == 2)
        #expect(Set(plan.bindings.values) == [entry.id])
        #expect(plan.renames.isEmpty)
    }

    @Test func restartKeepsOriginalPendingDeadline() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let account = try OpenChamberSyncAccount(nativeCredential("new"))
        let store = OpenChamberSyncStateStore(fileURL: url)
        let state = OpenChamberSyncState(hasBaseline: true, seenCredentialIDs: [], pendingSince: [:]).observing(accounts: [account], now: now)
        try store.save(state)
        let restored = try OpenChamberSyncStateStore(fileURL: url).load().observing(accounts: [account], now: now.addingTimeInterval(500))
        #expect(restored.pendingSince[account.id] == now)
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}

func syncProfile(_ entry: OpenCodeStoredCredential) throws -> PlusProfile {
    PlusProfile(id: UUID(), label: entry.label, openCodeOpenAIAccount: try entry.openAIIdentity(), emailLink: nil, detectedNote: nil,
                webDataStoreID: UUID(), sortOrder: 0, createdAt: .distantPast, lastRefreshAt: nil, lastKnownState: .unknown)
}
