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
    private let selector: any SelectorControlling
    init(resolveClient: @escaping @Sendable () async throws -> any OpenCodeCredentialServing = {
        guard let client = try await OpenCodeLocalRuntime.discover().credentials else { throw OpenCodeCredentialError.unavailable }
        return client
    }, snapshots: OpenCodeSignInSnapshotStore = .init(), verifier: any OpenCodeOpenAICredentialVerifying = OpenCodeOpenAICredentialVerifier(),
         gate: OpenCodeOperationGate = .shared, selector: (any SelectorControlling)? = nil) {
        self.resolveClient = resolveClient; self.snapshots = snapshots; self.verifier = verifier; self.gate = gate
        self.selector = selector ?? SelectorControlClient(homeDirectory: snapshots.homeDirectory)
    }
    func install(_ signIn: CodexSignIn, for profile: PlusProfile) async throws {
        defer { CloudSavedSessionChange.released() }
        try await selector.withMaintenance(reason: .signInRepair) {
            try await self.gate.withOperation { try await self.perform(signIn, profile: profile) }
        }
    }

    func installCloudSession(_ value: OpenCodeCredentialValue, for profile: PlusProfile, policy: CloudSessionInstallationPolicy,
                             authorization: CloudSessionAdoptionAuthorization) async throws -> OpenCodeOpenAIIdentity {
        defer { CloudSavedSessionChange.released() }
        return try await selector.withMaintenance(reason: .signInRepair) {
            try await self.gate.withOperation {
                try await self.performCloud(value, profile: profile, authorization: authorization)
            }
        }
    }

    private func performCloud(_ value: OpenCodeCredentialValue, profile: PlusProfile,
                              authorization: CloudSessionAdoptionAuthorization) async throws -> OpenCodeOpenAIIdentity {
        try Task.checkCancellation()
        try await authorization.check()
        let client = try await resolveClient()
        let before = try await client.inventory()
        try await authorization.check()
        let source = try value.auth(), identity = try source.identity()
        let receipts = try CloudSessionAdoptionReceiptStore(directory: snapshots.directory, key: authorization.receiptKey)
        let receipt = try receipts.load()
        var candidate = try snapshots.resolved(source)
        try await authorization.checkSource(.openChamber(value: .legacy(source), consumed: []),
            resolved: .openChamber(value: .legacy(candidate), consumed: []), receipt: receipt)
        let binding = try snapshots.binding(identity: identity)
        let matching = before.oauth.filter { (try? $0.openAIIdentity().matches(identity)) == true }
        let installed = receipt?.adoptedRemote == false ? nil : receipt?.nativeID.flatMap { id in matching.first { $0.id == id } }
        if let receipt, let installed {
            let fingerprint = try CloudSessionAdoptionReceipt.fingerprint(CloudJournalCoding.encode(installed.value))
            guard receipt.committed || fingerprint == receipt.targetFingerprint else { throw CloudSessionAdoptionError.changed }
        }
        let original = installed ?? matching.first(where: { $0.id == binding }) ?? matching.first(where: \.active) ?? matching.first
        let saved: OpenCodeCredentialValue?
        do { saved = try snapshots.loadNativeValue(identity: identity) }
        catch OpenCodeOpenAIAuthError.invalidCredential { throw OpenCodeOpenAIAuthError.invalidCredential }
        if let installed {
            let native = try snapshots.resolved(installed.value.auth())
            if native != candidate {
                let previous = candidate, snapshots = self.snapshots
                try await authorization.write {
                    try authorization.check(.openChamber(value: .legacy(native), consumed: []))
                    try snapshots.saveRefreshed(native, replacing: previous)
                }
                candidate = native
            }
        }
        if receipt == nil {
            let intent = CloudSessionAdoptionReceipt(sourceFingerprint: try CloudSessionPayload.openChamber(value: .legacy(source), consumed: []).generationFingerprint!,
                previousFingerprint: try original.map { CloudSessionAdoptionReceipt.fingerprint(try CloudJournalCoding.encode($0.value)) },
                targetFingerprint: try CloudSessionAdoptionReceipt.fingerprint(CloudJournalCoding.encode(value)),
                nativeID: nil, committed: false, recoveryStarted: true)
            try await authorization.write { try receipts.save(intent) }
        }
        // Prefer a working destination generation. Transport errors are never
        // evidence that this login can be overwritten by a remote snapshot.
        var localValues = [original?.value, saved].compactMap { $0 }
        if localValues.count == 2, localValues[0] == localValues[1] { localValues.removeLast() }
        for localValue in localValues {
            let local = try snapshots.resolved(localValue.auth())
            do {
                let selected = before.oauth.contains { $0.active && (try? $0.value.auth()) == local }
                let prepared = try await prepareCloud(local, selected: selected, before: before,
                    client: client, authorization: authorization)
                return try await publishCloud(prepared, source: source, template: localValue, original: original,
                    before: before, client: client, profile: profile, receipts: receipts,
                    authorization: authorization, remote: installed != nil || local == candidate)
            } catch OpenCodeOpenAIVerificationError.reauthenticationRequired { }
            catch OpenCodeOpenAIVerificationError.unauthorized { }
        }
        let prepared = try await prepareCloud(candidate, selected: false, before: before, client: client, authorization: authorization)
        return try await publishCloud(prepared, source: source, template: original?.value ?? saved ?? value, original: original,
            before: before, client: client, profile: profile, receipts: receipts, authorization: authorization, remote: true)
    }

    private func prepareCloud(_ auth: OpenCodeOpenAIAuth, selected: Bool, before: OpenCodeCredentialInventory,
                              client: any OpenCodeCredentialServing, authorization: CloudSessionAdoptionAuthorization) async throws -> OpenCodeOpenAIAuth {
        try await authorization.check(.openChamber(value: .legacy(auth), consumed: []))
        if !auth.needsRefresh(at: .now) {
            do { try await verifier.verify(auth); return auth }
            catch OpenCodeOpenAIVerificationError.unauthorized { }
        }
        // Native replacement requires activation to keep a selected consumed
        // connection usable. That belongs to explicit Switch, not saved-only.
        guard !selected else { throw CloudSessionAdoptionError.requiresSwitch }
        guard before.openAI.contains(where: \.active) else { throw CloudSessionAdoptionError.requiresSwitch }
        try Task.checkCancellation()
        try await checkCloudInventory(before, client: client, authorization: authorization)
        try await authorization.check(.openChamber(value: .legacy(auth), consumed: []))
        let fresh = try await verifier.refresh(auth)
        guard try fresh.identity().matches(auth.identity()) else { throw CloudSessionError.identityMismatch }
        try snapshots.saveRefreshed(fresh, replacing: auth)
        try Task.checkCancellation()
        try await authorization.check(.openChamber(value: .legacy(fresh), consumed: []))
        try await verifier.verify(fresh)
        return fresh
    }

    private func checkCloudInventory(_ before: OpenCodeCredentialInventory, client: any OpenCodeCredentialServing,
                                     authorization: CloudSessionAdoptionAuthorization) async throws {
        try await SelectorMaintenanceContext.check()
        let current = try await client.inventory()
        try await authorization.check()
        guard current.entries == before.entries, current.connectionIDs == before.connectionIDs else { throw CloudSessionAdoptionError.changed }
    }

    private func publishCloud(_ auth: OpenCodeOpenAIAuth, source: OpenCodeOpenAIAuth, template: OpenCodeCredentialValue,
                              original: OpenCodeStoredCredential?, before: OpenCodeCredentialInventory,
                              client: any OpenCodeCredentialServing, profile: PlusProfile, receipts: CloudSessionAdoptionReceiptStore,
                              authorization: CloudSessionAdoptionAuthorization, remote: Bool) async throws -> OpenCodeOpenAIIdentity {
        try Task.checkCancellation()
        let identity = try auth.identity(), value = template.replacingTokens(auth)
        let selected = before.openAI.first(where: \.active)
        let existing = before.oauth.first { $0.value == value }
        // The installed native API selects its first connection even when POST
        // says activate:false. Keep the inbox until the user explicitly switches.
        guard existing != nil || selected != nil else { throw CloudSessionAdoptionError.requiresSwitch }
        // Native route parameters have a length limit even though POST accepts
        // longer IDs. One digest stays addressable for later Switch/Remove.
        let id = try existing?.id ?? "cred_cloud_" + CloudSessionPayload.fingerprint(authorization.receiptKey + ":" + auth.refresh)
        var receipt = CloudSessionAdoptionReceipt(sourceFingerprint: try CloudSessionPayload.openChamber(value: .legacy(source), consumed: []).generationFingerprint!,
            previousFingerprint: try original.map { CloudSessionAdoptionReceipt.fingerprint(try CloudJournalCoding.encode($0.value)) },
            targetFingerprint: try CloudSessionAdoptionReceipt.fingerprint(CloudJournalCoding.encode(value)), nativeID: id,
            committed: false, recoveryStarted: remote, adoptedRemote: remote)
        try await checkCloudInventory(before, client: client, authorization: authorization)
        let intent = receipt
        try await authorization.write {
            try authorization.check(.openChamber(value: .legacy(auth), consumed: []))
            try receipts.save(intent)
        }
        if existing == nil {
            try await checkCloudInventory(before, client: client, authorization: authorization)
            do { _ = try await client.create(id: id, label: profile.label, value: value, activate: false) }
            catch {
                // A lost response is not permission to create another ID. Recover
                // the exact intent without cancellation, never activate or delete.
                let recovered = try await SelectorMaintenanceContext.settle { try await client.inventory() }
                guard recovered.entries.contains(where: { $0.id == id && $0.value == value }) else { throw error }
            }
        }
        let after = try await SelectorMaintenanceContext.settle { try await client.inventory() }
        guard let installed = after.entries.first(where: { $0.id == id }), installed.value == value,
              after.openAI.first(where: \.active)?.id == selected?.id,
              before.entries.allSatisfy({ old in after.entries.contains(old) }) else { throw CloudSessionAdoptionError.changed }
        receipt.committed = true
        // Readback has established the exact native commit. Retain that fact even
        // if cancellation or consent changes now prevent local binding/catalog work.
        try receipts.save(receipt)
        let snapshots = self.snapshots
        try Task.checkCancellation()
        return try await authorization.write {
            try authorization.check(.openChamber(value: .legacy(auth), consumed: []))
            try snapshots.saveNative(installed, identity: identity)
            try authorization.completed(.init(accountID: identity.accountID, userID: identity.userID, email: identity.email), .openChamber, remote)
            return identity
        }
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
            try await SelectorMaintenanceContext.check()
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
        try await SelectorMaintenanceContext.settle { try await self.publish(auth, profile: profile, before: before, client: client) }
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
        try await SelectorMaintenanceContext.check()
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
                try await SelectorMaintenanceContext.check()
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
