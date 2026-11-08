import Foundation

struct AppSignInRepairInstaller: AppSignInRepairInstalling {
    var desktop = CodexAccountSwitchService()
    var openChamber = OpenChamberRepairInstaller()
    func install(_ signIn: CodexSignIn, for profile: PlusProfile, destination: AppSignInDestination) async throws {
        switch destination {
        case .desktop: try await desktop.installRepaired(signIn, for: profile)
        case .openChamber: try await openChamber.install(signIn, for: profile)
        }
    }
}

actor OpenChamberRepairInstaller {
    private let resolveClient: @Sendable () async throws -> any OpenCodeCredentialServing
    private let snapshots: OpenCodeSignInSnapshotStore
    private let verifier: any OpenCodeOpenAICredentialVerifying
    private let gate: OpenCodeOperationGate
    init(resolveClient: @escaping @Sendable () async throws -> any OpenCodeCredentialServing = {
        guard let client = try await OpenCodeLocalRuntime.discover().credentials else { throw OpenCodeCredentialError.unavailable }
        return client
    }, snapshots: OpenCodeSignInSnapshotStore = .init(), verifier: any OpenCodeOpenAICredentialVerifying = OpenCodeOpenAICredentialVerifier(),
         gate: OpenCodeOperationGate = .shared) {
        self.resolveClient = resolveClient; self.snapshots = snapshots; self.verifier = verifier; self.gate = gate
    }
    func install(_ signIn: CodexSignIn, for profile: PlusProfile) async throws {
        try await gate.withOperation { try await self.perform(signIn, profile: profile) }
    }
    private func perform(_ signIn: CodexSignIn, profile: PlusProfile) async throws {
        try signIn.validateRepair(for: profile)
        let client = try await resolveClient()
        var auth = try snapshots.resolved(signIn.openChamberAuth())
        let identity = try auth.identity()
        var before = try await client.inventory()
        let matching = before.oauth.filter { (try? $0.openAIIdentity().matches(identity)) == true }
        let receiptIDs = [repairID(signIn.refreshToken), repairID(auth.refresh)]
        // Native OAuth may rotate this grant after a partial repair. Its stable
        // credential ID is the receipt; never reinstall the consumed original.
        let installed = matching.first(where: { receiptIDs.contains($0.id) })
        if let installed {
            let native = try installed.value.auth()
            let adopted = try snapshots.resolved(native)
            if adopted != auth {
                // Connect the original grant to a native rotation before a later
                // controlled refresh can replace the stable native receipt ID.
                try snapshots.saveRefreshed(adopted, replacing: auth)
                auth = adopted
            }
            if auth != native {
                before = try await settle(auth, profile: profile, before: before, client: client)
            }
        }
        var refresh = auth.needsRefresh(at: .now)
        if !refresh {
            do { try await verifier.verify(auth) }
            catch OpenCodeOpenAIVerificationError.unauthorized { refresh = true }
        }
        if refresh {
            try Task.checkCancellation()
            guard try await client.inventory().entries == before.entries else { throw AppSignInRepairError.changed }
            let fresh = try await verifier.refresh(auth)
            guard try fresh.identity().matches(identity) else { throw AppSignInRepairError.identityMismatch }
            try snapshots.saveRefreshed(fresh, replacing: auth)
            auth = fresh
            if installed != nil {
                before = try await settle(auth, profile: profile, before: before, client: client)
            }
            try Task.checkCancellation()
            try await verifier.verify(auth)
        }
        try Task.checkCancellation()
        _ = try await settle(auth, profile: profile, before: before, client: client)
    }

    /// Preserve a consumed installed generation even if the caller is cancelled.
    private func settle(_ auth: OpenCodeOpenAIAuth, profile: PlusProfile, before: OpenCodeCredentialInventory,
                        client: any OpenCodeCredentialServing) async throws -> OpenCodeCredentialInventory {
        try await Task.detached { try await self.publish(auth, profile: profile, before: before, client: client) }.value
    }

    private func publish(_ auth: OpenCodeOpenAIAuth, profile: PlusProfile, before: OpenCodeCredentialInventory,
                         client: any OpenCodeCredentialServing) async throws -> OpenCodeCredentialInventory {
        let identity = try auth.identity()
        let matching = before.oauth.filter { (try? $0.openAIIdentity().matches(identity)) == true }
        let selected = before.openAI.first(where: \.active)
        let original = matching.first(where: \.active) ?? matching.first
        let existing = matching.first(where: { (try? $0.value.auth()) == auth })
        let value = (original?.value ?? .legacy(auth)).replacingTokens(auth)
        // Stable per grant: retry a lost POST response without creating another credential.
        let id = existing?.id ?? repairID(auth.refresh)
        let current = try await client.inventory()
        guard current.entries == before.entries else { throw AppSignInRepairError.changed }
        let activate = selected == nil || original?.id == selected?.id
        let expectedValue = existing?.value ?? value
        if let existing {
            if activate, !existing.active { try await client.activate(id: existing.id) }
        } else {
            do { _ = try await client.create(id: id, label: profile.label, value: value, activate: activate) }
            catch {
                guard try await client.inventory().entries.contains(where: { $0.id == id && $0.value == value }) else { throw error }
            }
        }
        let after = try await client.inventory()
        guard let saved = after.entries.first(where: { $0.id == id }), saved.value == expectedValue,
              after.openAI.first(where: \.active)?.id == (activate ? id : selected?.id) else { throw AppSignInRepairError.changed }
        try snapshots.saveNative(saved, identity: identity)
        for old in matching where old.id != id {
            let latest = try await client.inventory()
            guard latest.openAI.first(where: \.active)?.id == (activate ? id : selected?.id) else { throw AppSignInRepairError.changed }
            if let unchanged = latest.entries.first(where: { $0.id == old.id }), !unchanged.active, unchanged.value == old.value {
                try await client.remove(id: old.id)
            }
        }
        return try await client.inventory()
    }

    private func repairID(_ refresh: String) -> String { "cred_repair_" + signInRepairDigest(refresh) }
}

import CryptoKit
private func signInRepairDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
