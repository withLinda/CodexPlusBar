import Foundation

protocol OpenChamberSyncServing: Sendable {
    func reconcile(catalog: OpenChamberSyncCatalog,
                   isCurrent: @escaping @Sendable (UInt64) async -> Bool) async throws -> OpenChamberSyncResult
}

actor OpenChamberSyncService: OpenChamberSyncServing {
    private let resolveClient: @Sendable () async throws -> any OpenCodeCredentialServing
    private let gate: OpenCodeOperationGate
    private let snapshots: OpenCodeSignInSnapshotStore
    private let stateStore: OpenChamberSyncStateStore
    private let verifier: any OpenCodeOpenAICredentialVerifying
    private let now: @Sendable () -> Date

    init(resolveClient: @escaping @Sendable () async throws -> any OpenCodeCredentialServing = {
        guard let client = try await OpenCodeLocalRuntime.discover().credentials else { throw OpenCodeCredentialError.unavailable }
        return client
    }, gate: OpenCodeOperationGate = .shared, snapshots: OpenCodeSignInSnapshotStore = .init(),
         stateStore: OpenChamberSyncStateStore = .init(), verifier: any OpenCodeOpenAICredentialVerifying = OpenCodeOpenAICredentialVerifier(),
         now: @escaping @Sendable () -> Date = { .now }) {
        self.resolveClient = resolveClient; self.gate = gate; self.snapshots = snapshots
        self.stateStore = stateStore; self.verifier = verifier; self.now = now
    }

    func reconcile(catalog: OpenChamberSyncCatalog, isCurrent: @escaping @Sendable (UInt64) async -> Bool) async throws -> OpenChamberSyncResult {
        try await gate.withOperation { try await self.perform(catalog: catalog, isCurrent: isCurrent) }
    }

    private func perform(catalog: OpenChamberSyncCatalog, isCurrent: @escaping @Sendable (UInt64) async -> Bool) async throws -> OpenChamberSyncResult {
        guard catalog.isTrusted else { throw OpenChamberSyncError.catalogUnavailable }
        try await check(catalog, isCurrent)
        let client = try await resolveClient()
        var inventory = try await client.inventory()
        var accounts = try inventory.oauth.map(OpenChamberSyncAccount.init)
        var state = try stateStore.load().observing(accounts: accounts, now: now())
        try await check(catalog, isCurrent)
        try stateStore.save(state)
        var savedBindings: [String: String] = [:]
        for profile in catalog.profiles where profile.provider == .codex {
            if let identity = profile.openCodeOpenAIAccount { savedBindings[identity.storageKey] = try snapshots.binding(identity: identity) }
        }
        func plan(_ accounts: [OpenChamberSyncAccount], _ state: OpenChamberSyncState) throws -> OpenChamberSyncPlan {
            try OpenChamberSyncPlanner.plan(catalog: catalog, accounts: accounts, savedBindings: savedBindings, state: state, now: now())
        }
        var intended = try plan(accounts, state)
        var failedRestore: Set<UUID> = []
        for id in intended.restoreProfileIDs {
            try await check(catalog, isCurrent)
            guard let profile = catalog.profiles.first(where: { $0.id == id }), let identity = profile.openCodeOpenAIAccount else { continue }
            // A previous restoration of another local row may already satisfy this identity.
            inventory = try await client.inventory()
            accounts = try inventory.oauth.map(OpenChamberSyncAccount.init)
            if accounts.contains(where: { $0.identity.matches(identity) }) { continue }
            guard var value = try snapshots.loadNativeValue(identity: identity) else { failedRestore.insert(id); continue }
            let auth = try value.auth()
            do {
                var refresh = auth.needsRefresh(at: now())
                if !refresh {
                    do { try await verifier.verify(auth) }
                    catch OpenCodeOpenAIVerificationError.unauthorized { refresh = true }
                }
                if refresh {
                    let rotated = try await verifier.refresh(auth)
                    guard try rotated.identity().matches(identity) else { throw OpenCodeOpenAIAuthError.identityMismatch }
                    value = value.replacingTokens(rotated)
                    // Refresh may consume the old token: persist before cancellation or the next network request.
                    try snapshots.saveValue(value, identity: identity)
                    try await verifier.verify(rotated)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failedRestore.insert(id); continue }
            try await check(catalog, isCurrent)
            let latest = try await client.inventory()
            guard try summaries(latest) == summaries(inventory) else { throw OpenChamberSyncError.changed }
            let newID = "cred_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            state.seenCredentialIDs.insert(newID)
            try stateStore.save(state)
            try await check(catalog, isCurrent)
            let created = try await client.create(id: newID, label: profile.label, value: value, activate: false)
            try snapshots.saveNative(created, identity: identity)
        }

        inventory = try await client.inventory()
        accounts = try inventory.oauth.map(OpenChamberSyncAccount.init)
        state = state.observing(accounts: accounts, now: now())
        intended = try plan(accounts, state)
        for (profileID, credentialID) in intended.bindings {
            guard let profile = catalog.profiles.first(where: { $0.id == profileID }), let identity = profile.openCodeOpenAIAccount,
                  let entry = inventory.oauth.first(where: { $0.id == credentialID }) else { throw OpenChamberSyncError.changed }
            try await check(catalog, isCurrent)
            try snapshots.saveNative(entry, identity: identity)
            state.pendingSince.removeValue(forKey: credentialID)
        }
        try stateStore.save(state)
        for id in intended.renames.keys.sorted() {
            try await check(catalog, isCurrent)
            let latest = try await client.inventory()
            guard try summaries(latest) == summaries(inventory) else { throw OpenChamberSyncError.changed }
            try await check(catalog, isCurrent)
            try await client.rename(id: id, label: intended.renames[id]!)
            inventory = try await client.inventory()
        }

        var deferred = false
        // Inactive extras first. Active removal is handled last and only after an idle check.
        let removalOrder = intended.removeIDs.sorted { a, b in
            let aActive = inventory.openAI.contains { $0.id == a && $0.active }
            let bActive = inventory.openAI.contains { $0.id == b && $0.active }
            return aActive == bActive ? a < b : !aActive
        }
        for id in removalOrder {
            try await check(catalog, isCurrent)
            let latest = try await client.inventory()
            guard try summaries(latest) == summaries(inventory) else { throw OpenChamberSyncError.changed }
            inventory = latest
            guard let target = inventory.oauth.first(where: { $0.id == id }) else { continue }
            if target.active {
                guard (try? await client.hasRunningSessions()) == false else { deferred = true; continue }
                try await check(catalog, isCurrent)
                if let replacement = intended.replacementActiveID {
                    try await client.activate(id: replacement)
                    let activated = try await client.inventory()
                    guard activated.openAI.first(where: \.active)?.id == replacement else { throw OpenChamberSyncError.changed }
                    inventory = activated
                }
            }
            try await check(catalog, isCurrent)
            let beforeDelete = try await client.inventory()
            guard try summaries(beforeDelete) == summaries(inventory) else { throw OpenChamberSyncError.changed }
            try await check(catalog, isCurrent)
            try await client.remove(id: id)
            inventory = try await client.inventory()
        }
        try await check(catalog, isCurrent)
        let finalInventory = try await client.inventory()
        let finalAccounts = try finalInventory.oauth.map(OpenChamberSyncAccount.init)
        state = state.observing(accounts: finalAccounts, now: now())
        let finalPlan = try plan(finalAccounts, state)
        try stateStore.save(state)
        guard finalPlan.removeIDs.allSatisfy({ id in deferred && finalInventory.oauth.contains { $0.id == id && $0.active } }),
              finalPlan.renames.isEmpty else { throw OpenChamberSyncError.changed }
        let missing = finalPlan.needsSignInProfileIDs.union(finalPlan.restoreProfileIDs).union(failedRestore.subtracting(finalPlan.bindings.keys))
        return OpenChamberSyncResult(matchedCount: finalPlan.bindings.count, totalCount: catalog.profiles.filter { $0.provider == .codex }.count,
                                    needsSignInProfileIDs: missing, pendingCredentialCount: finalPlan.pendingCredentialIDs.count, deferredActiveRemoval: deferred)
    }

    private func check(_ catalog: OpenChamberSyncCatalog, _ isCurrent: @Sendable (UInt64) async -> Bool) async throws {
        try Task.checkCancellation()
        guard await isCurrent(catalog.generation) else { throw OpenChamberSyncError.changed }
        try Task.checkCancellation()
    }
    private func summaries(_ inventory: OpenCodeCredentialInventory) throws -> [String] {
        // Ignore rotating token bytes, but include all account selection/membership changes.
        try inventory.openAI.map { entry in
            let identity = entry.value.type == "oauth" ? try entry.openAIIdentity().storageKey : entry.value.type ?? "unknown"
            return "\(entry.id)|\(identity)|\(entry.active)|\(entry.label)"
        }.sorted()
    }
}
