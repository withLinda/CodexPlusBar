import Foundation

protocol OpenChamberSignInChecking: Sendable {
    func check(profiles: [PlusProfile], didCheck: @escaping @Sendable (OpenChamberSignInCheckUpdate) async -> Void) async throws
}

actor OpenChamberSignInCheckService: OpenChamberSignInChecking {
    private let resolveClient: @Sendable () async throws -> any OpenCodeCredentialServing
    private let snapshots: OpenCodeSignInSnapshotStore
    private let verifier: any OpenCodeOpenAICredentialVerifying
    private let gate: OpenCodeOperationGate
    private let now: @Sendable () -> Date

    init(resolveClient: @escaping @Sendable () async throws -> any OpenCodeCredentialServing = {
        guard let client = try await OpenCodeLocalRuntime.discover().credentials else { throw OpenCodeCredentialError.unavailable }
        return client
    }, snapshots: OpenCodeSignInSnapshotStore = .init(),
         verifier: any OpenCodeOpenAICredentialVerifying = OpenCodeOpenAICredentialVerifier(),
         gate: OpenCodeOperationGate = .shared, now: @escaping @Sendable () -> Date = { .now }) {
        self.resolveClient = resolveClient; self.snapshots = snapshots; self.verifier = verifier
        self.gate = gate; self.now = now
    }

    func check(profiles: [PlusProfile], didCheck: @escaping @Sendable (OpenChamberSignInCheckUpdate) async -> Void) async throws {
        try await gate.withOperation { try await self.perform(profiles: profiles, didCheck: didCheck) }
    }

    private func perform(profiles: [PlusProfile], didCheck: @escaping @Sendable (OpenChamberSignInCheckUpdate) async -> Void) async throws {
        let client = try await resolveClient()
        // Establish a trustworthy inventory before attributing any failure to an account.
        _ = try await client.inventory()
        var checked: [String: OpenChamberSignInCheckOutcome] = [:]
        for profile in profiles where profile.provider == .codex {
            try Task.checkCancellation()
            let outcome: OpenChamberSignInCheckOutcome
            if let identity = profile.openCodeOpenAIAccount {
                if let previous = checked[identity.storageKey] { outcome = previous }
                else {
                    outcome = try await checkIdentity(identity, client: client)
                    checked[identity.storageKey] = outcome
                }
            } else { outcome = .needsSignIn }
            try Task.checkCancellation()
            await didCheck(.init(profileID: profile.id, record: .init(identityKey: profile.openCodeOpenAIAccount?.storageKey,
                                                                  outcome: outcome, checkedAt: now())))
        }
    }

    private func checkIdentity(_ identity: OpenCodeOpenAIIdentity,
                               client: any OpenCodeCredentialServing) async throws -> OpenChamberSignInCheckOutcome {
        do {
            let inventory = try await client.inventory()
            var binding = try snapshots.binding(identity: identity)
            var expected = try candidates(for: identity, binding: binding, in: inventory)
            var entry = expected.first
            let value: OpenCodeCredentialValue
            if let entry {
                value = entry.value
                try snapshots.saveNative(entry, identity: identity)
            } else if let saved = try snapshots.loadNativeValue(identity: identity) { value = saved }
            else { return .needsSignIn }

            let stored = try value.auth()
            var auth = try snapshots.resolved(stored)
            if auth != stored, let original = entry {
                let replacement = try await publish(auth, replacing: original, inventory: inventory, client: client)
                entry = replacement
                binding = replacement.id
                expected.removeAll { $0.id == original.id }; expected.append(replacement)
            }
            do {
                var refresh = auth.needsRefresh(at: now())
                if !refresh {
                    do { try await verifier.verify(auth) }
                    catch OpenCodeOpenAIVerificationError.unauthorized { refresh = true }
                }
                if refresh {
                    try Task.checkCancellation()
                    // Capture immediately before refresh; publishing must not override a selection
                    // or native token rotation that happened while the request was in flight.
                    let before = try await client.inventory()
                    try requireCandidatesUnchanged(identity, binding: binding, expected: expected, in: before)
                    let fresh = try await verifier.refresh(auth)
                    guard try fresh.identity().matches(identity) else { throw OpenCodeOpenAIAuthError.identityMismatch }
                    try snapshots.saveRefreshed(fresh, replacing: auth)
                    auth = fresh
                    if let original = entry {
                        // Finish preserving consumed-token replacements even after Cancel.
                        let replacement = try await Task.detached {
                            try await self.publish(fresh, replacing: original, inventory: before, client: client)
                        }.value
                        entry = replacement
                        binding = replacement.id
                        expected.removeAll { $0.id == original.id }; expected.append(replacement)
                    }
                    try Task.checkCancellation()
                    try await verifier.verify(fresh)
                }
                try requireCandidatesUnchanged(identity, binding: binding, expected: expected, in: await client.inventory())
                return .verified
            } catch let error as OpenCodeOpenAIVerificationError where error == .reauthenticationRequired || error == .unauthorized {
                // A concurrent re-sign-in/rotation invalidates evidence about the old pair.
                try requireCandidatesUnchanged(identity, binding: binding, expected: expected, in: await client.inventory())
                return .needsSignIn
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return .unchecked }
    }

    private func requireUnchanged(_ entry: OpenCodeStoredCredential, in inventory: OpenCodeCredentialInventory) throws {
        guard let current = inventory.entries.first(where: { $0.id == entry.id }),
              current.value == entry.value else { throw OpenCodeOpenAIAuthError.changedWhileReading }
    }

    private func candidates(for identity: OpenCodeOpenAIIdentity, binding: String?,
                            in inventory: OpenCodeCredentialInventory) throws -> [OpenCodeStoredCredential] {
        // A stored but unreadable binding is not proof that the sign-in is missing.
        if let bound = inventory.entries.first(where: { $0.id == binding }) {
            guard try bound.openAIIdentity().matches(identity) else { throw OpenCodeOpenAIAuthError.changedWhileReading }
        }
        var matches: [OpenCodeStoredCredential] = [], unreadable = false
        for entry in inventory.oauth {
            do { if try entry.openAIIdentity().matches(identity) { matches.append(entry) } }
            catch { unreadable = true }
        }
        guard !matches.isEmpty || !unreadable else { throw OpenCodeCredentialError.invalidResponse }
        return preferred(matches, binding: binding)
    }

    private func preferred(_ entries: [OpenCodeStoredCredential], binding: String?) -> [OpenCodeStoredCredential] {
        entries.sorted {
            if $0.active != $1.active { return $0.active }
            if ($0.id == binding) != ($1.id == binding) { return $0.id == binding }
            return $0.id < $1.id
        }
    }

    private func requireCandidatesUnchanged(_ identity: OpenCodeOpenAIIdentity, binding: String?,
                                            expected: [OpenCodeStoredCredential], in inventory: OpenCodeCredentialInventory) throws {
        let current = try candidates(for: identity, binding: binding, in: inventory)
        guard current.count == expected.count,
              current.first?.id == preferred(expected, binding: binding).first?.id,
              expected.allSatisfy({ entry in current.contains { $0.id == entry.id && $0.value == entry.value } }) else {
            throw OpenCodeOpenAIAuthError.changedWhileReading
        }
    }

    /// The native API imports values but PATCH only edits labels. Replace a token pair
    /// through supported APIs, retaining metadata and the selected account identity.
    private func publish(_ auth: OpenCodeOpenAIAuth, replacing original: OpenCodeStoredCredential,
                         inventory: OpenCodeCredentialInventory, client: any OpenCodeCredentialServing) async throws -> OpenCodeStoredCredential {
        let current = try await client.inventory()
        try requireUnchanged(original, in: current)
        let identity = try original.openAIIdentity()
        try requireCandidatesUnchanged(identity, binding: original.id,
            expected: candidates(for: identity, binding: original.id, in: inventory), in: current)
        guard current.openAI.first(where: \.active) == inventory.openAI.first(where: \.active) else {
            throw OpenCodeOpenAIAuthError.changedWhileReading
        }
        // OpenCode auto-selects the first credential. Do not import into a store
        // without an active connection; the durable snapshot remains available.
        guard let selected = current.openAI.first(where: \.active) else { throw OpenCodeOpenAIAuthError.changedWhileReading }
        let id = "cred_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let value = original.value.replacingTokens(auth)
        let activate = selected.id == original.id
        do { _ = try await client.create(id: id, label: original.label, value: value, activate: activate) }
        catch {
            // POST may have committed before a dropped response. Read back its exact ID.
            let after = try await client.inventory()
            guard after.entries.contains(where: { $0.id == id && $0.value == value }) else { throw error }
        }
        let after = try await client.inventory()
        guard let created = after.entries.first(where: { $0.id == id }), created.value == value,
              after.openAI.first(where: \.active)?.id == (activate ? id : selected.id) else {
            throw OpenCodeOpenAIAuthError.changedWhileReading
        }
        try snapshots.saveNative(created, identity: auth.identity())
        // Only retire the predecessor if it is still byte-for-byte ours and inactive.
        let latest = try await client.inventory()
        if let old = latest.entries.first(where: { $0.id == original.id }), !old.active, old.value == original.value {
            try await client.remove(id: original.id)
        }
        return created
    }
}
