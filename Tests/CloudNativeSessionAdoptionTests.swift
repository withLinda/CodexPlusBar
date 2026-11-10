import Foundation
import Testing
@testable import CodexPlusBar

@MainActor struct CloudNativeSessionAdoptionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCHAMBER_V2_TEST_URL"] != nil))
    func isolatedCloudAdoptionRebuildsBindingWithoutChangingSelection() async throws {
        try await IsolatedOpenChamberTestGate.shared.run {
            let raw = try #require(ProcessInfo.processInfo.environment["OPENCHAMBER_V2_TEST_URL"])
            let directory = try #require(ProcessInfo.processInfo.environment["OPENCHAMBER_NATIVE_TEST_DIRECTORY"])
            let client = OpenCodeCredentialClient(baseURL: try #require(URL(string: raw)),
                authorization: "Basic " + Data("opencode:fixture-password".utf8).base64EncodedString(), directory: directory,
                request: { request in
                    let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
                    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
                    let (data, response) = try await session.data(for: request)
                    let http = try #require(response as? HTTPURLResponse)
                    if http.statusCode >= 300 { Issue.record("Isolated native HTTP \(request.httpMethod ?? "GET") \(request.url?.path ?? "") returned \(http.statusCode)") }
                    return (data, http)
                })
            let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
            let before = try await client.inventory()
            let selected = try #require(before.openAI.first { $0.active })
            let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "cloud-adoption", refresh: UUID().uuidString))
            var old = try OpenCodeCredentialValue.legacy(fresh.openChamberAuth())
            old.fields["refresh"] = .string("rejected")
            old.fields["metadata"] = .object(["accountID": .string(fresh.identity.accountID), "extra": .string("keep-local")])
            let predecessor = try await client.create(id: "cred_cloud_fixture_old", label: "Local", value: old, activate: false)
            #expect(predecessor.value.fields["metadata"] == old.fields["metadata"])
            let store = OpenCodeSignInSnapshotStore(homeDirectory: home)
            let installer = OpenChamberRepairInstaller(resolveClient: { client }, snapshots: store,
                verifier: AdoptionNativeVerifier(), gate: .init(), selector: MaintenanceTestControl(state: .paused))
            let profile = CodexSignInFixture.profile()
            let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(profile), openChamber: installer)
            let identity = try await adapter.adoptOpenChamber(.openChamber(value: .legacy(fresh.openChamberAuth()), consumed: []), for: profile)
            let after = try await client.inventory()
            let id = try #require(try store.binding(identity: identity))
            let installed = try #require(after.entries.first { $0.id == id })
            #expect(installed.id != predecessor.id)
            #expect(installed.value.fields["metadata"] == old.fields["metadata"])
            #expect(installed.active == false)
            #expect(after.openAI.first(where: \.active)?.id == selected.id)
            #expect(before.entries.allSatisfy { after.entries.contains($0) })
            #expect(after.entries.contains(predecessor))
            _ = try await adapter.adoptOpenChamber(.openChamber(value: .legacy(fresh.openChamberAuth()), consumed: []), for: profile)
            #expect(try await client.inventory().entries.count == after.entries.count)
            try await client.remove(id: id); try await client.remove(id: predecessor.id)
        }
    }

    @Test(arguments: [false, true])
    func desktopWorkingLocalIsPreferredAndNetworkFailureIsInconclusive(networkError: Bool) async throws {
        let local = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let remote = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let verifier = AdoptionDesktopVerifier(verify: { candidate in
            #expect(candidate == local)
            if networkError { throw URLError(.timedOut) }
        })
        let f = try NativeSwitchFixture(verifier: verifier); defer { f.cleanUp() }
        try f.vault.save(local)
        let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile), desktop: f.service)
        if networkError {
            await #expect(throws: URLError.self) { try await adapter.adoptDesktop(.desktop(signIn: remote, consumed: []), for: f.profile) }
        } else { _ = try await adapter.adoptDesktop(.desktop(signIn: remote, consumed: []), for: f.profile) }
        #expect(try f.vault.load(local.identity) == local)
        #expect(await verifier.verifications == 1)
        #expect(await verifier.refreshes == 0)
    }

    @Test(arguments: ["profile", "account", "user"])
    func mismatchedIdentityNeverReachesDesktopProvider(mismatch: String) async throws {
        let verifier = AdoptionDesktopVerifier(), f = try NativeSwitchFixture(verifier: verifier)
        defer { f.cleanUp() }
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        var profile = f.profile
        if mismatch == "profile" { profile = profile.reidentified(UUID()) }
        else { profile.codexSignIn = .init(accountID: mismatch == "account" ? "different" : source.identity.accountID,
            userID: mismatch == "user" ? "different" : source.identity.userID, email: source.identity.email) }
        let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile), desktop: f.service)
        await #expect(throws: CloudSessionError.identityMismatch) {
            try await adapter.adoptDesktop(.desktop(signIn: source, consumed: []), for: profile)
        }
        #expect(await verifier.verifications == 0)
    }

    @Test(arguments: ["stale", "consumed"])
    func coordinatorRejectsStaleOrUnownedConsumedRequest(reason: String) async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key())
        let f = try SessionFixture(inboxKeys: keys); defer { f.clean() }
        let verifier = AdoptionDesktopVerifier(), native = try NativeSwitchFixture(verifier: verifier)
        defer { native.cleanUp() }
        f.nativeAdoption = { .init(authorization: $0, desktop: native.service) }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), source = UUID()
        let request = try await receiveAdoption(.desktop(signIn: old, consumed: []), in: f, keys: keys, source: source)
        let new = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        _ = try await receiveAdoption(.desktop(signIn: new, consumed: reason == "consumed" ? [CloudSessionPayload.fingerprint(old.refreshToken)] : []),
            in: f, keys: keys, source: reason == "stale" ? source : UUID(), revision: 2)
        await #expect(throws: CloudSessionError.unavailable) { try await f.coordinator.adoptSession(request) }
        #expect(await verifier.verifications == 0)
        #expect(!FileManager.default.fileExists(atPath: native.vault.url(for: old.identity).path))
        await f.coordinator.stop()
    }

    @Test func controllerRejectsCompetingActionsDuringImport() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        try f.profiles.beginCloudSessionAdoption(for: f.profile.id)
        defer { f.profiles.finishCloudSessionAdoption() }
        #expect(!f.profiles.canRepairAppSignIns)
        #expect(!f.profiles.canCheckOpenChamberSignIns)
        await f.profiles.removeProfile(id: f.profile.id)
        await f.profiles.clearSession(for: f.profile.id)
        await f.profiles.refreshAll()
        await f.profiles.saveDesktopSignIn(profileID: f.profile.id)
        #expect(try f.store.loadProfiles() == [f.profile])
        #expect(f.profiles.cloudSessionAdoptionAllowed(for: f.profile.id))
    }

    @Test func completionPreservesLatestDiskDetailsAndClearsRejectedAnnotation() throws {
        let f = try SessionFixture(); defer { f.clean() }
        let identity = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)).identity
        var latest = f.profile
        latest.notes = "A newer disk edit"
        latest.openCodeOpenAIAccount = .init(accountID: identity.accountID, userID: identity.userID, email: identity.email)
        latest.openChamberSignInCheck = .init(identityKey: latest.openCodeOpenAIAccount?.storageKey, outcome: .needsSignIn, checkedAt: .now)
        try f.store.saveProfiles([latest])
        try f.profiles.beginCloudSessionAdoption(for: f.profile.id)
        defer { f.profiles.finishCloudSessionAdoption() }
        try f.profiles.completeCloudSessionAdoption(identity: identity, kind: .openChamber, profileID: f.profile.id)
        let saved = try #require(try f.store.loadProfiles().first)
        #expect(saved.notes == "A newer disk edit")
        #expect(saved.currentOpenChamberSignInCheck?.outcome == .verified)
        #expect(!f.profiles.openChamberSignInNeedsRepair(for: f.profile.id))
    }

    @Test(arguments: ["off", "sessions", "draft", "arrival", "deleted", "owner"])
    func coordinatorRechecksLifecycleAfterVerification(reason: String) async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key())
        let f = try SessionFixture(inboxKeys: keys); defer { f.clean() }
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let barrier = SyncBarrier()
        let verifier = AdoptionDesktopVerifier(verify: { _ in await barrier.wait() })
        let native = try NativeSwitchFixture(verifier: verifier); defer { native.cleanUp() }
        f.nativeAdoption = { .init(authorization: $0, desktop: native.service) }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let request = try await receiveAdoption(.desktop(signIn: source, consumed: []), in: f, keys: keys)
        let operation = Task { try? await f.coordinator.adoptSession(request) }
        await barrier.started()
        switch reason {
        case "off": await f.coordinator.setEnabled(false)
        case "sessions": await f.coordinator.setIncludesSessions(false)
        case "draft": f.profiles.setCloudDraftOwner(f.profile.id)
        case "arrival":
            let other = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
            _ = try await receiveAdoption(.desktop(signIn: other, consumed: [CloudSessionPayload.fingerprint(source.refreshToken)]), in: f, keys: keys)
        case "deleted": try f.store.saveProfiles([])
        default:
            f.currentOwner = .init(container: f.owner.container, environment: f.owner.environment, userRecordName: "different")
            await f.coordinator.syncNow()
        }
        await barrier.release(); _ = await operation.value
        #expect(!FileManager.default.fileExists(atPath: native.vault.url(for: source.identity).path))
        #expect(await verifier.refreshes == 0)
        await f.coordinator.stop()
    }

    @Test func nativeConsumedSourceWithoutReceiptIsRejectedBeforeProvider() async throws {
        let f = try AdoptionOpenFixture(); defer { f.clean() }
        let source = try f.payload()
        CloudSavedSessionChange.consumed(try #require(try source.generationFingerprint), kind: .openChamber)
        await #expect(throws: CloudSessionError.unavailable) { try await f.adapter().adoptOpenChamber(source, for: f.profile) }
        #expect(await f.verifier.verifications.isEmpty)
        #expect(await f.client.operations.isEmpty)
    }

    @Test func nativeEmptySelectionDoesNotConsumeTokenBeforeRequiringSwitch() async throws {
        let f = try AdoptionOpenFixture(selected: false); defer { f.clean() }
        let source = try f.payload(expired: true)
        await #expect(throws: CloudSessionAdoptionError.requiresSwitch) { try await f.adapter().adoptOpenChamber(source, for: f.profile) }
        #expect(await f.verifier.refreshes.isEmpty)
        #expect(await f.client.operations.isEmpty)
    }

    @Test func nativeCancelledRefreshRetainsOwnedRecoveryAcrossRestart() async throws {
        let barrier = SyncBarrier()
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)).openChamberAuth()
        let verifier = AdoptionOpenVerifier(refresh: { _ in await barrier.wait(); return fresh })
        let f = try AdoptionOpenFixture(verifier: verifier); defer { f.clean() }
        let source = try f.payload(expired: true), adapter = f.adapter()
        let operation = Task { try? await adapter.adoptOpenChamber(source, for: f.profile) }
        await barrier.started(); operation.cancel(); await barrier.release()
        #expect(await operation.value == nil)
        #expect(try f.store.resolved(source.openAuth()) == fresh)
        let retryVerifier = AdoptionOpenVerifier()
        _ = try await f.adapter(verifier: retryVerifier).adoptOpenChamber(source, for: f.profile)
        #expect(await retryVerifier.refreshes.isEmpty)
        #expect(try f.store.loadNativeValue(identity: fresh.identity())?.auth() == fresh)
        #expect(await f.client.inventory().openAI.first(where: \.active)?.id == f.selected?.id)
    }

    @Test func cancelledNativeCreatePersistsConfirmedReceiptBeforeLaterRotation() async throws {
        let f = try AdoptionOpenFixture(); defer { f.clean() }
        let source = try f.payload(), barrier = SyncBarrier()
        let client = AdoptionCreateBarrierClient(base: f.client, barrier: barrier)
        let installer = OpenChamberRepairInstaller(resolveClient: { client }, snapshots: f.store,
            verifier: f.verifier, gate: .init(), selector: MaintenanceTestControl(state: .paused))
        let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile), openChamber: installer)
        let operation = Task { try? await adapter.adoptOpenChamber(source, for: f.profile) }
        await barrier.started(); operation.cancel(); await barrier.release()
        #expect(await operation.value == nil)
        let id = try #require(await f.client.inventory().oauth.first { $0.id != f.selected?.id }?.id)
        #expect(try f.store.binding(identity: source.openAuth().identity()) == nil)
        let rotated = try f.payload().openAuth()
        await f.client.replaceValue(id: id, value: .legacy(rotated))
        _ = try await f.adapter().adoptOpenChamber(source, for: f.profile)
        #expect(try f.store.loadNativeValue(identity: rotated.identity())?.auth() == rotated)
        #expect(await f.client.inventory().openAI.first(where: \.active)?.id == f.selected?.id)
    }

    @Test func backupWaitsForImportAndRevokesItsFinalWrite() async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key()), barrier = SyncBarrier()
        let f = try SessionFixture(inboxKeys: keys); defer { f.clean() }
        let verifier = AdoptionDesktopVerifier(verify: { _ in await barrier.wait() })
        let native = try NativeSwitchFixture(verifier: verifier); defer { native.cleanUp() }
        f.nativeAdoption = { .init(authorization: $0, desktop: native.service) }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let request = try await receiveAdoption(.desktop(signIn: source, consumed: []), in: f, keys: keys)
        let operation = Task { try? await f.coordinator.adoptSession(request) }
        await barrier.started()
        let pause = Task { try await f.profiles.pauseForBackup() }
        // Yield only until the synchronous transfer admission is observed.
        while !f.profiles.isTransferring { await Task.yield() }
        #expect(f.profiles.isImportingCloudSession)
        await barrier.release(); _ = await operation.value
        try await pause.value
        #expect(!f.profiles.isImportingCloudSession)
        #expect(!FileManager.default.fileExists(atPath: native.vault.url(for: source.identity).path))
        f.profiles.resumeAfterBackup(reload: false, startTasks: false)
        await f.coordinator.stop()
    }

    @Test func desktopCatalogFailureKeepsVerifiedLoginAndRetriesWithoutRefresh() async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        var authorization = adoptionAuthorization(f.profile)
        authorization.completed = { _, _, _ in throw AppSignInRepairError.storageFailed }
        let adapter = CloudNativeSessionAdoption(authorization: authorization, desktop: f.service)
        await #expect(throws: AppSignInRepairError.storageFailed) {
            try await adapter.adoptDesktop(.desktop(signIn: source, consumed: []), for: f.profile)
        }
        #expect(try f.vault.load(source.identity) == source)
        let retry = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile), desktop: f.service)
        _ = try await retry.adoptDesktop(.desktop(signIn: source, consumed: []), for: f.profile)
        #expect(try f.vault.load(source.identity) == source)
    }

    @Test func nativeCommittedReceiptFollowsExternalThenControlledRotationAcrossRetry() async throws {
        let f = try AdoptionOpenFixture(); defer { f.clean() }
        let source = try f.payload()
        let identity = try await f.adapter().adoptOpenChamber(source, for: f.profile)
        let installedID = try #require(try f.store.binding(identity: identity))
        let b = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: true)).openChamberAuth()
        let c = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)).openChamberAuth()
        await f.client.replaceValue(id: installedID, value: .legacy(b))
        let verifier = AdoptionOpenVerifier(verify: { _ in throw URLError(.timedOut) }, refresh: { _ in c })
        await #expect(throws: URLError.self) { try await f.adapter(verifier: verifier).adoptOpenChamber(source, for: f.profile) }
        #expect(try f.store.resolved(source.openAuth()) == c)
        let retry = AdoptionOpenVerifier()
        _ = try await f.adapter(verifier: retry).adoptOpenChamber(source, for: f.profile)
        #expect(await retry.refreshes.isEmpty)
        #expect(await retry.verifications == [c.refresh])
        #expect(try f.store.loadNativeValue(identity: identity)?.auth() == c)
        #expect(await f.client.inventory().openAI.first(where: \.active)?.id == f.selected?.id)
        #expect(await f.client.operations.allSatisfy { $0.hasPrefix("create:") })
    }

    @Test(arguments: [false, true])
    func workingNativeLocalIsPreferredAndNetworkErrorCannotReplaceIt(networkError: Bool) async throws {
        let verifier = AdoptionOpenVerifier(verify: { _ in if networkError { throw URLError(.timedOut) } })
        let f = try AdoptionOpenFixture(verifier: verifier); defer { f.clean() }
        let local = try f.payload().openAuth(), remote = try f.payload()
        let entry = OpenCodeStoredCredential(id: "cred_local", integrationID: "openai", label: "local", active: false, value: .legacy(local))
        await f.client.append(entry)
        if networkError {
            await #expect(throws: URLError.self) { try await f.adapter().adoptOpenChamber(remote, for: f.profile) }
        } else {
            _ = try await f.adapter().adoptOpenChamber(remote, for: f.profile)
            #expect(try f.store.loadNativeValue(identity: local.identity())?.auth() == local)
        }
        #expect(await verifier.verifications == [local.refresh])
        #expect(await f.client.operations.isEmpty)
    }

    @Test func rejectedNativeConnectionDoesNotHideWorkingLocalSavedSnapshot() async throws {
        let f = try AdoptionOpenFixture(); defer { f.clean() }
        let local = try f.payload().openAuth(), remote = try f.payload()
        try f.store.saveValue(.legacy(local), identity: local.identity())
        var rejected = OpenCodeCredentialValue.legacy(local); rejected.fields["refresh"] = .string("rejected")
        await f.client.append(.init(id: "cred_rejected_local", integrationID: "openai", label: "local", active: false, value: rejected))
        let installer = OpenChamberRepairInstaller(resolveClient: { f.client }, snapshots: f.store,
            verifier: AdoptionNativeVerifier(), gate: .init(), selector: MaintenanceTestControl(state: .paused))
        let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile), openChamber: installer)
        _ = try await adapter.adoptOpenChamber(remote, for: f.profile)
        #expect(try f.store.loadNativeValue(identity: local.identity())?.auth() == local)
        #expect(await f.client.inventory().oauth.contains { (try? $0.value.auth()) == local })
        #expect(await f.client.inventory().oauth.allSatisfy { (try? $0.value.auth()) != (try? remote.openAuth()) })
    }

    @Test func repeatedLocalPreferenceDoesNotInventRemoteConsumption() async throws {
        let f = try AdoptionOpenFixture(); defer { f.clean() }
        let local = try f.payload().openAuth(), remote = try f.payload()
        await f.client.append(.init(id: "cred_working", integrationID: "openai", label: "local", active: false, value: .legacy(local)))
        _ = try await f.adapter().adoptOpenChamber(remote, for: f.profile)
        _ = try await f.adapter().adoptOpenChamber(remote, for: f.profile)
        #expect(try f.store.resolved(remote.openAuth()) == remote.openAuth())
        #expect(!CloudSavedSessionChange.isConsumed(try #require(try remote.generationFingerprint), kind: .openChamber))
        #expect(await f.client.operations.isEmpty)
    }

    @Test func sameSourceLocalRefreshKeepsRetryOwnership() async throws {
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)).openChamberAuth()
        let verifier = AdoptionOpenVerifier(refresh: { _ in fresh })
        let f = try AdoptionOpenFixture(verifier: verifier); defer { f.clean() }
        let source = try f.payload(expired: true), old = try source.openAuth()
        try f.store.saveValue(.legacy(old), identity: old.identity())
        _ = try await f.adapter().adoptOpenChamber(source, for: f.profile)
        _ = try await f.adapter().adoptOpenChamber(source, for: f.profile)
        #expect(await verifier.refreshes == [old.refresh])
        #expect(try f.store.loadNativeValue(identity: old.identity())?.auth() == fresh)
    }

    @Test func encryptedReceiptDoesNotInstallAndCancelledImportRetriesThroughCoordinator() async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key())
        let f = try SessionFixture(inboxKeys: keys); defer { f.clean() }
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: true))
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let verifier = PendingNativeRefresh(fresh: fresh)
        let native = try NativeSwitchFixture(verifier: verifier); defer { native.cleanUp() }
        let selected = try nativeCredential("untouched", active: true)
        let client = SyncTestClient([selected])
        let openStore = OpenCodeSignInSnapshotStore(homeDirectory: native.home)
        let open = OpenChamberRepairInstaller(resolveClient: { client }, snapshots: openStore,
            verifier: AdoptionNativeVerifier(), gate: .init(), selector: MaintenanceTestControl(state: .paused))
        f.nativeAdoption = { .init(authorization: $0, desktop: native.service, openChamber: open) }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let request = try await receiveAdoption(.desktop(signIn: source, consumed: []), in: f, keys: keys)
        #expect(try await f.coordinator.sessionSummaries(for: f.profile.id).count == 1)
        #expect(!FileManager.default.fileExists(atPath: native.vault.directory.path))
        #expect(!FileManager.default.fileExists(atPath: openStore.directory.path))
        #expect(await client.operations.isEmpty)
        let operation = Task { try? await f.coordinator.adoptSession(request) }
        await verifier.waitForStart(); operation.cancel(); await verifier.finish()
        _ = await operation.value
        #expect(try native.vault.latestGeneration(of: source) == fresh)
        let retryVerifier = AdoptionDesktopVerifier()
        let restarted = try NativeSwitchFixture(home: native.home, verifier: retryVerifier)
        f.nativeAdoption = { .init(authorization: $0, desktop: restarted.service, openChamber: open) }
        try await f.coordinator.adoptSession(request)
        #expect(try f.store.loadProfiles().first?.codexSignIn == fresh.identity)
        #expect(await retryVerifier.refreshes == 0)
        #expect(await client.operations.isEmpty)
        await f.coordinator.stop()
    }

    @Test func desktopRevocationDuringVerificationPreventsRefresh() async throws {
        let barrier = SyncBarrier(), admission = AdoptionAdmissionFlag()
        let signIn = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let verifier = AdoptionDesktopVerifier(verify: { candidate in
            if candidate.refreshToken == signIn.refreshToken {
                await barrier.wait(); throw CodexSignInError.unauthorized
            }
        }, refresh: { _ in fresh })
        let f = try NativeSwitchFixture(verifier: verifier); defer { f.cleanUp() }
        let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile) { try admission.check() }, desktop: f.service)
        let operation = Task { try? await adapter.adoptDesktop(.desktop(signIn: signIn, consumed: []), for: f.profile) }
        await barrier.started()
        admission.allowed = false
        await barrier.release()
        #expect(await operation.value == nil)
        #expect(await verifier.refreshes == 0)
        #expect(!FileManager.default.fileExists(atPath: f.vault.url(for: signIn.identity).path))
    }

    @Test func desktopRevocationDuringRefreshSettlesPairButStopsFurtherVerification() async throws {
        let barrier = SyncBarrier(), admission = AdoptionAdmissionFlag()
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: true))
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let verifier = AdoptionDesktopVerifier(refresh: { _ in await barrier.wait(); return fresh })
        let f = try NativeSwitchFixture(verifier: verifier); defer { f.cleanUp() }
        let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile) { try admission.check() }, desktop: f.service)
        let operation = Task { try? await adapter.adoptDesktop(.desktop(signIn: source, consumed: []), for: f.profile) }
        await barrier.started(); admission.allowed = false; await barrier.release()
        #expect(await operation.value == nil)
        #expect(try f.vault.latestGeneration(of: source) == fresh)
        #expect(await verifier.verifications == 0)
        #expect(await verifier.refreshes == 1)
    }

    @Test func productionNativeClientRechecksGenerationBeforePost() async throws {
        let value = try OpenCodeCredentialValue.legacy(CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)).openChamberAuth())
        let client = OpenCodeCredentialClient(baseURL: URL(string: "http://127.0.0.1:1")!, authorization: nil, request: { _ in
            Issue.record("Stale generation reached the HTTP request boundary")
            throw OpenCodeCredentialError.unavailable
        })
        var authorization = adoptionAuthorization(CodexSignInFixture.profile())
        authorization.validateGeneration = { _ in throw CloudSessionError.unavailable }
        await #expect(throws: CloudSessionError.unavailable) {
            try await CloudSessionAdoptionContext.$authorization.withValue(authorization) {
                try await client.create(id: "cred_fixture", label: "fixture", value: value, activate: false)
            }
        }
    }

    @Test func consumedDesktopSourceWithoutOwnReceiptNeverReachesProvider() async throws {
        let signIn = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        CloudSavedSessionChange.consumed(CloudSessionPayload.fingerprint(signIn.refreshToken), kind: .desktop)
        let verifier = AdoptionDesktopVerifier()
        let f = try NativeSwitchFixture(verifier: verifier); defer { f.cleanUp() }
        let adapter = CloudNativeSessionAdoption(authorization: adoptionAuthorization(f.profile), desktop: f.service)
        await #expect(throws: CloudSessionError.unavailable) {
            try await adapter.adoptDesktop(.desktop(signIn: signIn, consumed: []), for: f.profile)
        }
        #expect(await verifier.verifications == 0)
        #expect(!FileManager.default.fileExists(atPath: f.vault.url(for: signIn.identity).path))
    }

    @Test func cancelledDesktopRefreshCanRetryOwnConsumedSourceAfterRestart() async throws {
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: true))
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let verifier = PendingNativeRefresh(fresh: fresh)
        let f = try NativeSwitchFixture(verifier: verifier); defer { f.cleanUp() }
        let authorization = adoptionAuthorization(f.profile)
        let adapter = CloudNativeSessionAdoption(authorization: authorization, desktop: f.service)
        let operation = Task { try? await adapter.adoptDesktop(.desktop(signIn: source, consumed: []), for: f.profile) }
        await verifier.waitForStart(); operation.cancel(); await verifier.finish()
        #expect(await operation.value == nil)
        #expect(try f.vault.latestGeneration(of: source) == fresh)
        let nextVerifier = AdoptionDesktopVerifier()
        let restarted = try NativeSwitchFixture(home: f.home, verifier: nextVerifier)
        let retry = CloudNativeSessionAdoption(authorization: authorization, desktop: restarted.service)
        #expect(try await retry.adoptDesktop(.desktop(signIn: source, consumed: []), for: f.profile) == fresh.identity)
        #expect(await nextVerifier.refreshes == 0)
        #expect(await nextVerifier.verifications == 1)
        #expect(try f.vault.load(fresh.identity) == fresh)
        #expect(await f.app.events.isEmpty)
    }

    @Test func desktopRefreshMappingSurvivesMainSnapshotWriteFailure() async throws {
        let source = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: true))
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let vault = CodexSignInVault(homeDirectory: home), destination = vault.url(for: source.identity)
        let verifier = AdoptionDesktopVerifier(refresh: { _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            return fresh
        })
        let f = try NativeSwitchFixture(home: home, verifier: verifier)
        let auth = adoptionAuthorization(f.profile)
        let adapter = CloudNativeSessionAdoption(authorization: auth, desktop: f.service)
        await #expect(throws: CodexSignInError.storageFailed) {
            try await adapter.adoptDesktop(.desktop(signIn: source, consumed: []), for: f.profile)
        }
        #expect(try vault.latestGeneration(of: source) == fresh)
        try FileManager.default.removeItem(at: destination)
        let retryVerifier = AdoptionDesktopVerifier()
        let restarted = try NativeSwitchFixture(home: home, verifier: retryVerifier)
        let retry = CloudNativeSessionAdoption(authorization: auth, desktop: restarted.service)
        _ = try await retry.adoptDesktop(.desktop(signIn: source, consumed: []), for: f.profile)
        #expect(try vault.load(fresh.identity) == fresh)
        #expect(await retryVerifier.refreshes == 0)
    }

    @Test func missingDesktopSnapshotAdoptsWithoutLabelProofOrLiveWrite() async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        var profile = f.profile; profile.label = "A remote profile, not an email"
        let signIn = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let live = try CodexSignInFixture.data(account: "unrelated")
        try live.write(to: f.authURL)
        let adoption = CloudNativeSessionAdoption(authorization: adoptionAuthorization(profile), desktop: f.service)
        let identity = try await adoption.adoptDesktop(.desktop(signIn: signIn, consumed: []), for: profile)
        #expect(identity == signIn.identity)
        #expect(try f.vault.load(identity) == signIn)
        #expect(try Data(contentsOf: f.authURL) == live)
        #expect(await f.app.events.isEmpty)
    }

    @Test func nativeAdoptionRebuildsBindingKeepsMetadataSelectionAndLostCreate() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let signIn = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let profile = CodexSignInFixture.profile(), store = OpenCodeSignInSnapshotStore(homeDirectory: home)
        var oldValue = try OpenCodeCredentialValue.legacy(signIn.openChamberAuth())
        oldValue.fields["refresh"] = .string("rejected")
        oldValue.fields["metadata"] = .object(["accountID": .string(signIn.identity.accountID), "custom": .string("preserved")])
        let old = OpenCodeStoredCredential(id: "cred_destination_old", integrationID: "openai", label: "Local metadata", active: false, value: oldValue)
        let selected = try nativeCredential("unrelated", active: true)
        let client = SyncTestClient([selected, old], loseCreateResponse: true)
        let native = OpenChamberRepairInstaller(resolveClient: { client }, snapshots: store,
            verifier: AdoptionNativeVerifier(), gate: .init(), selector: MaintenanceTestControl(state: .paused))
        let adoption = CloudNativeSessionAdoption(authorization: adoptionAuthorization(profile), openChamber: native)
        let identity = try await adoption.adoptOpenChamber(.openChamber(value: .legacy(signIn.openChamberAuth()), consumed: []), for: profile)
        let after = await client.inventory()
        let saved = try #require(after.oauth.first { (try? $0.value.auth().refresh) == signIn.refreshToken })
        #expect(try store.binding(identity: identity) == saved.id)
        #expect(saved.id != old.id)
        #expect(saved.value.fields["metadata"] == oldValue.fields["metadata"])
        #expect(after.openAI.first(where: \.active) == selected)
        #expect(after.entries.contains(old))
        #expect(try store.loadNativeValue(identity: identity) == saved.value)
    }
}

func adoptionAuthorization(_ profile: PlusProfile, record: String = "session.fixture", validate: @escaping @MainActor @Sendable () throws -> Void = {}) -> CloudSessionAdoptionAuthorization {
    .init(owner: CloudCryptoFixture.owner, request: .init(profileID: profile.id, recordName: record, sourceRevision: 1), validate: validate)
}

struct AdoptionNativeVerifier: OpenCodeOpenAICredentialVerifying {
    func verify(_ auth: OpenCodeOpenAIAuth) async throws {
        if auth.refresh == "rejected" { throw OpenCodeOpenAIVerificationError.unauthorized }
    }
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth {
        throw OpenCodeOpenAIVerificationError.reauthenticationRequired
    }
}

@MainActor final class AdoptionAdmissionFlag {
    var allowed = true
    func check() throws { if !allowed { throw CloudSessionError.unavailable } }
}

actor AdoptionDesktopVerifier: CodexSignInVerifying {
    var verifications = 0
    var refreshes = 0
    let onVerify: @Sendable (CodexSignIn) async throws -> Void
    let onRefresh: @Sendable (CodexSignIn) async throws -> CodexSignIn
    init(verify: @escaping @Sendable (CodexSignIn) async throws -> Void = { _ in },
         refresh: @escaping @Sendable (CodexSignIn) async throws -> CodexSignIn = { $0 }) {
        onVerify = verify; onRefresh = refresh
    }
    func verify(_ signIn: CodexSignIn) async throws { verifications += 1; try await onVerify(signIn) }
    func refresh(_ signIn: CodexSignIn) async throws -> CodexSignIn { refreshes += 1; return try await onRefresh(signIn) }
}

@MainActor func receiveAdoption(_ payload: CloudSessionPayload, in f: SessionFixture, keys: CloudTransportKeys,
                               source: UUID = UUID(), revision: UInt64 = 1) async throws -> CloudSessionAdoptionRequest {
    let document = try sessionDocument(profile: f.profile, payload: payload, source: source, revision: revision)
    let codec = CloudRecordCodec(assets: .init(root: f.root.appendingPathComponent("adoption-staging")))
    let encoded = try codec.encode(.session(document), owner: f.owner, key: keys.writer)
    defer { encoded.lease.release() }
    let envelope = try codec.envelope(from: encoded.record)
    try await f.journal.receive(id: envelope.id, recordName: envelope.recordName,
        metadata: CloudJournalCoding.encode(envelope.routing), ciphertext: envelope.ciphertext)
    return .init(profileID: f.profile.id, recordName: envelope.recordName, sourceRevision: revision)
}

actor AdoptionOpenVerifier: OpenCodeOpenAICredentialVerifying {
    var verifications: [String] = [], refreshes: [String] = []
    let onVerify: @Sendable (OpenCodeOpenAIAuth) async throws -> Void
    let onRefresh: @Sendable (OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth
    init(verify: @escaping @Sendable (OpenCodeOpenAIAuth) async throws -> Void = { _ in },
         refresh: @escaping @Sendable (OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth = { $0 }) {
        onVerify = verify; onRefresh = refresh
    }
    func verify(_ auth: OpenCodeOpenAIAuth) async throws { verifications.append(auth.refresh); try await onVerify(auth) }
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth { refreshes.append(auth.refresh); return try await onRefresh(auth) }
}

@MainActor struct AdoptionOpenFixture {
    let home: URL
    let profile = CodexSignInFixture.profile()
    let store: OpenCodeSignInSnapshotStore
    let client: SyncTestClient
    let selected: OpenCodeStoredCredential?
    let verifier: AdoptionOpenVerifier
    init(selected: Bool = true, verifier: AdoptionOpenVerifier = .init()) throws {
        home = try CodexSignInFixture.directory(); store = .init(homeDirectory: home)
        self.selected = selected ? try nativeCredential("other", active: true) : nil
        client = SyncTestClient(self.selected.map { [$0] } ?? [])
        self.verifier = verifier
    }
    func payload(expired: Bool = false) throws -> CloudSessionPayload {
        .openChamber(value: .legacy(try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: expired)).openChamberAuth()), consumed: [])
    }
    func adapter(verifier: AdoptionOpenVerifier? = nil) -> CloudNativeSessionAdoption {
        let installer = OpenChamberRepairInstaller(resolveClient: { [client] in client }, snapshots: store,
            verifier: verifier ?? self.verifier, gate: .init(), selector: MaintenanceTestControl(state: .paused))
        return .init(authorization: adoptionAuthorization(profile), openChamber: installer)
    }
    func clean() { try? FileManager.default.removeItem(at: home) }
}

extension CloudSessionPayload {
    func openAuth() throws -> OpenCodeOpenAIAuth {
        guard case .openChamber(let value, _) = self else { throw CloudSessionError.invalidPayload }
        return try value.auth()
    }
}

struct AdoptionCreateBarrierClient: OpenCodeCredentialServing {
    let base: SyncTestClient
    let barrier: SyncBarrier
    func inventory() async throws -> OpenCodeCredentialInventory { await base.inventory() }
    func create(id: String, label: String, value: OpenCodeCredentialValue, activate: Bool) async throws -> OpenCodeStoredCredential {
        let result = try await base.create(id: id, label: label, value: value, activate: activate)
        await barrier.wait()
        return result
    }
    func rename(id: String, label: String) async throws { await base.rename(id: id, label: label) }
    func activate(id: String) async throws { await base.activate(id: id) }
    func remove(id: String) async throws { try await base.remove(id: id) }
    func hasRunningSessions() async throws -> Bool { await base.hasRunningSessions() }
}
