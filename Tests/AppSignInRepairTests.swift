import Foundation
import Testing
@testable import CodexPlusBar

struct AppSignInRepairTests {
    @Test func ambiguousDesktopCommitRequestsNewAuthorizationWithoutReusingReceipt() async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        let profile = try f.installTarget()
        let a = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "interrupted"))
        let b = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "external"))
        let c = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "new-desktop"))
        let d = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "new-openchamber"))
        try f.vault.save(a)
        try f.vault.saveRepairIntent(for: a, previous: Data(contentsOf: f.authURL), target: a.data)
        try b.data.write(to: f.authURL)
        let store = AppSignInRepairStore(homeDirectory: f.home)
        try store.save(a, profile: profile, destination: .desktop)
        let authorizer = RepairAuthorizer([c, d])
        let service = AppSignInRepairService(authorizer: authorizer, installer: RepairDesktopInstaller(desktop: f.service), store: store)
        try await service.repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { _ in }, isCurrent: { true })
        #expect(await authorizer.calls == 2)
        #expect(try Data(contentsOf: f.authURL) == c.data)
    }

    @Test(arguments: ["before", "after", "rotated-before", "rotated-after"])
    func desktopRetryReconcilesInterruptedInstallationIntent(state: String) async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        let profile = try f.installTarget()
        let previous = try CodexSignInFixture.data(account: "selected", refresh: "old")
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "repair"))
        let rotated = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "native-rotated"))
        try previous.write(to: f.authURL)
        try f.vault.save(fresh)
        try f.vault.saveRepairIntent(for: fresh, previous: previous, target: fresh.data)
        // Crash either before the live write, or after the write followed by
        // native rotation but before its completion receipt could be persisted.
        if state == "after" { try fresh.data.write(to: f.authURL) }
        if state.hasPrefix("rotated") { try rotated.data.write(to: f.authURL) }
        let retry = try NativeSwitchFixture(home: f.home)
        if state.hasPrefix("rotated") {
            await #expect(throws: AppSignInRepairError.interruptedInstallation) {
                try await retry.service.installRepaired(fresh, for: profile)
            }
            #expect(try Data(contentsOf: f.authURL) == rotated.data)
            #expect(try f.vault.load(fresh.identity) == fresh)
        } else {
            try await retry.service.installRepaired(fresh, for: profile)
            #expect(try Data(contentsOf: f.authURL) == fresh.data)
        }
    }

    @Test func failedCatalogCompletionRetainsGrantsForRetry() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let profile = CodexSignInFixture.profile(), store = AppSignInRepairStore(homeDirectory: home)
        let a = try CodexSignIn(data: CodexSignInFixture.data(refresh: "desktop"))
        let b = try CodexSignIn(data: CodexSignInFixture.data(refresh: "openchamber"))
        let auth = RepairAuthorizer([a, b]), installer = RepairInstaller()
        let service = AppSignInRepairService(authorizer: auth, installer: installer, store: store)
        await #expect(throws: AppSignInRepairError.storageFailed) {
            try await service.repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { completion in
                if completion.destination == .openChamber { throw AppSignInRepairError.storageFailed }
            }, isCurrent: { true })
        }
        #expect(try store.load(profile, .desktop) == a)
        #expect(try store.load(profile, .openChamber) == b)
        let completed = RepairCompletions()
        try await AppSignInRepairService(authorizer: auth, installer: installer, store: store)
            .repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { await completed.append($0) }, isCurrent: { true })
        #expect(await completed.destinations == [.desktop, .openChamber])
        #expect(await auth.calls == 2)
    }

    @Test func desktopRetryPreservesRotationFromRunningApp() async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        let profile = try f.installTarget()
        let first = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "repair-first"))
        try CodexSignInFixture.data(account: "selected", refresh: "old").write(to: f.authURL)
        try await f.service.installRepaired(first, for: profile)
        let rotated = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "desktop-rotation"))
        try rotated.data.write(to: f.authURL)
        let restarted = try NativeSwitchFixture(home: f.home)
        try await restarted.service.installRepaired(first, for: profile)
        #expect(try Data(contentsOf: f.authURL) == rotated.data)
        #expect(try f.vault.load(first.identity) == rotated)
        let captured = try #require(try await restarted.service.captureSavedSession(for: profile))
        if case .desktop(let signIn, let consumed) = captured {
            #expect(signIn == rotated)
            #expect(consumed.contains(CloudSessionPayload.fingerprint(first.refreshToken)))
        } else { Issue.record("Expected repaired desktop snapshot") }
    }

    @Test func desktopCancellationAfterRefreshPreservesInstalledReplacement() async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        let profile = try f.installTarget()
        let expired = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "expired", expired: true))
        try expired.data.write(to: f.authURL)
        try await f.service.installRepaired(expired, for: profile)
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "rotated"))
        let verifier = PendingNativeRefresh(fresh: fresh)
        let retry = try NativeSwitchFixture(home: f.home, verifier: verifier)
        let task = Task { try await retry.service.installRepaired(expired, for: profile) }
        await verifier.waitForStart(); task.cancel(); await verifier.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: f.authURL) == fresh.data)
    }

    @Test(arguments: [false, true])
    func nativeRotationRemainsRecoverableAfterRefresh(cancel: Bool) async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let a = try CodexSignIn(data: CodexSignInFixture.data(refresh: "receipt-a"))
        let b = try CodexSignIn(data: CodexSignInFixture.data(refresh: "native-b", expired: true))
        let c = try CodexSignIn(data: CodexSignInFixture.data(refresh: "fresh-c"))
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: home)
        let client = SyncTestClient([try nativeCredential("other", active: true)])
        try await OpenChamberRepairInstaller(resolveClient: { client }, snapshots: snapshots, verifier: SyncTestVerifier(), gate: .init(), selector: MaintenanceTestControl(state: .paused))
            .install(a, for: CodexSignInFixture.profile())
        let installed = try #require(await client.inventory().oauth.first { (try? $0.value.auth().refresh) == "receipt-a" })
        await client.replaceValue(id: installed.id, value: try installed.value.replacingTokens(b.openChamberAuth()))
        await client.activate(id: installed.id)
        let barrier = cancel ? SyncBarrier() : nil
        let verifier = RepairRotationVerifier(fresh: try c.openChamberAuth(), barrier: barrier)
        let selector = MaintenanceTestControl(state: .auto)
        let retry = OpenChamberRepairInstaller(resolveClient: { client }, snapshots: snapshots, verifier: verifier, gate: .init(), selector: selector)
        let task = Task { try await retry.install(a, for: CodexSignInFixture.profile()) }
        if let barrier {
            await barrier.started(); task.cancel(); await barrier.release()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else { try await task.value }
        #expect(try await client.inventory().openAI.first(where: \.active)?.value.auth().refresh == "fresh-c")
        #expect(await selector.events.last == "end")
        #expect(await selector.state == .paused)
        // Original receipt must reach C across an app restart, including when
        // native rotation B was adopted before our controlled refresh B -> C.
        try await OpenChamberRepairInstaller(resolveClient: { client }, snapshots: snapshots, verifier: verifier, gate: .init(), selector: MaintenanceTestControl(state: .paused))
            .install(a, for: CodexSignInFixture.profile())
        #expect(try await client.inventory().openAI.first(where: \.active)?.value.auth().refresh == "fresh-c")
    }

    @Test func separateGrantsAndPartialRetrySurviveNewService() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let profile = CodexSignInFixture.profile(), store = AppSignInRepairStore(homeDirectory: home)
        let a = try CodexSignIn(data: CodexSignInFixture.data(refresh: "desktop"))
        let b = try CodexSignIn(data: CodexSignInFixture.data(refresh: "openchamber"))
        let auth = RepairAuthorizer([a, b]), installer = RepairInstaller(failure: .openChamber)
        let service = AppSignInRepairService(authorizer: auth, installer: installer, store: store)
        let completed = RepairCompletions()
        await #expect(throws: CodexSignInError.unavailable) {
            try await service.repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { await completed.append($0) }, isCurrent: { true })
        }
        #expect(await completed.destinations == [.desktop])
        #expect(try store.load(profile, .desktop)?.refreshToken == "desktop")
        #expect(try store.load(profile, .openChamber)?.refreshToken == "openchamber")
        await installer.setFailure(nil)
        let retry = AppSignInRepairService(authorizer: auth, installer: installer, store: store)
        try await retry.repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { await completed.append($0) }, isCurrent: { true })
        #expect(await auth.calls == 2)
        #expect(await completed.destinations == [.desktop, .desktop, .openChamber])
        #expect(try store.load(profile, .desktop) == nil)
        #expect(try store.load(profile, .openChamber) == nil)
    }

    @Test func wrongWorkspaceAndSharedRefreshTokensCannotInstallBoth() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let a = try CodexSignIn(data: CodexSignInFixture.data(refresh: "same"))
        var profile = CodexSignInFixture.profile(); profile.codexSignIn = a.identity
        let wrong = try CodexSignIn(data: CodexSignInFixture.data(account: "wrong"))
        let installer = RepairInstaller()
        let service = AppSignInRepairService(authorizer: RepairAuthorizer([wrong]), installer: installer, store: .init(homeDirectory: home))
        await #expect(throws: AppSignInRepairError.identityMismatch) {
            try await service.repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { _ in }, isCurrent: { true })
        }
        #expect(await installer.destinations.isEmpty)
        let shared = AppSignInRepairService(authorizer: RepairAuthorizer([a, a]), installer: installer, store: .init(homeDirectory: home))
        await #expect(throws: AppSignInRepairError.sharedCredential) {
            try await shared.repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { _ in }, isCurrent: { true })
        }
        #expect(await installer.destinations == [.desktop])
    }

    @Test func cancellationAfterAuthorizationKeepsGrantBeforeAnyInstallation() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let signIn = try CodexSignIn(data: CodexSignInFixture.data()), barrier = SyncBarrier()
        let profile = CodexSignInFixture.profile(), store = AppSignInRepairStore(homeDirectory: home)
        let installer = RepairInstaller(), auth = RepairAuthorizer([signIn], barrier: barrier)
        let service = AppSignInRepairService(authorizer: auth, installer: installer, store: store)
        let task = Task { try await service.repair(profile: profile, openURL: { _ in }, progress: { _ in }, completed: { _ in }, isCurrent: { true }) }
        await barrier.started(); task.cancel(); await barrier.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try store.load(profile, .desktop) == signIn)
        #expect(await installer.destinations.isEmpty)
    }

    @Test func desktopRepairPreservesUnrelatedSelectionAndReopensMatchingAccount() async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        let profile = try f.installTarget()
        let original = try Data(contentsOf: f.authURL)
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "fresh"))
        try await f.service.installRepaired(fresh, for: profile)
        #expect(try Data(contentsOf: f.authURL) == original)
        #expect(await f.app.events.isEmpty)
        try CodexSignInFixture.data(account: "selected", refresh: "old").write(to: f.authURL)
        try await f.service.installRepaired(fresh, for: profile)
        #expect(try Data(contentsOf: f.authURL) == fresh.data)
        #expect(await f.app.events == ["close", "open"])
    }

    @Test func desktopRepairRetryDoesNotHideFailedReopen() async throws {
        let f = try NativeSwitchFixture(app: NativeAppStub(openError: .reopenFailed)); defer { f.cleanUp() }
        let profile = try f.installTarget()
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "fresh"))
        try CodexSignInFixture.data(account: "selected", refresh: "old").write(to: f.authURL)
        for _ in 0..<2 {
            await #expect(throws: CodexSignInError.reopenFailed) {
                try await f.service.installRepaired(fresh, for: profile)
            }
        }
        #expect(try Data(contentsOf: f.authURL) == fresh.data)
    }

    @Test func nativeRepairPreservesOtherSelectionMetadataAndLostResponse() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: "fresh"))
        var value = try OpenCodeCredentialValue.legacy(fresh.openChamberAuth())
        value.fields["refresh"] = .string("old")
        value.fields["metadata"] = .object(["accountID": .string(fresh.identity.accountID), "extra": .string("keep")])
        let old = OpenCodeStoredCredential(id: "cred_old", integrationID: "openai", label: "Old", active: false, value: value)
        let selected = try nativeCredential("other", active: true)
        let client = SyncTestClient([selected, old], loseCreateResponse: true)
        let installer = OpenChamberRepairInstaller(resolveClient: { client }, snapshots: .init(homeDirectory: home), verifier: SyncTestVerifier(), gate: .init(), selector: MaintenanceTestControl(state: .paused))
        try await installer.install(fresh, for: CodexSignInFixture.profile())
        let inventory = await client.inventory()
        #expect(inventory.openAI.first(where: \.active) == selected)
        #expect(!inventory.entries.contains { $0.id == old.id })
        let saved = try #require(inventory.oauth.first { (try? $0.value.auth().refresh) == "fresh" })
        #expect(saved.value.fields["metadata"] == value.fields["metadata"])
        try await installer.install(fresh, for: CodexSignInFixture.profile())
        #expect(await client.inventory().entries == inventory.entries)
    }

    @Test func retryUsesNativeRotationAndRepairsAStaleSelectedDuplicate() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(refresh: "repair-first"))
        let client = SyncTestClient([try nativeCredential("other", active: true)])
        let installer = OpenChamberRepairInstaller(resolveClient: { client }, snapshots: .init(homeDirectory: home), verifier: SyncTestVerifier(), gate: .init(), selector: MaintenanceTestControl(state: .paused))
        try await installer.install(fresh, for: CodexSignInFixture.profile())
        let saved = try #require(await client.inventory().oauth.first { (try? $0.value.auth().refresh) == "repair-first" })
        let rotated = try CodexSignIn(data: CodexSignInFixture.data(refresh: "native-rotation"))
        await client.replaceValue(id: saved.id, value: try saved.value.replacingTokens(rotated.openChamberAuth()))
        try await installer.install(fresh, for: CodexSignInFixture.profile())
        #expect(try await client.inventory().entries.first(where: { $0.id == saved.id })?.value.auth().refresh == "native-rotation")
        var oldValue = saved.value; oldValue.fields["refresh"] = .string("stale")
        let stale = OpenCodeStoredCredential(id: "cred_stale", integrationID: "openai", label: "Old", active: false, value: oldValue)
        await client.append(stale); await client.activate(id: stale.id)
        try await installer.install(fresh, for: CodexSignInFixture.profile())
        let after = await client.inventory()
        #expect(after.openAI.first(where: \.active)?.id == saved.id)
        #expect(!after.entries.contains { $0.id == stale.id })
    }

    @Test(arguments: ["https://evil.example/oauth/authorize", "https://auth.openai.com.evil.example/oauth/authorize", "http://auth.openai.com/oauth/authorize", "https://auth.openai.com/oauth/authorize?state=x"])
    func rejectsUnsupportedAuthorizationURLs(raw: String) throws {
        #expect(throws: AppSignInRepairError.invalidAuthorization) { try CodexBrowserAuthorization.validateURL(URL(string: raw)!) }
    }
}

actor RepairAuthorizer: AppSignInAuthorizing {
    var grants: [CodexSignIn]
    var calls = 0
    let barrier: SyncBarrier?
    init(_ grants: [CodexSignIn], barrier: SyncBarrier? = nil) { self.grants = grants; self.barrier = barrier }
    func authorize(profile: PlusProfile, openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> CodexSignIn {
        calls += 1
        if let barrier { await barrier.wait() }
        guard !grants.isEmpty else { throw AppSignInRepairError.denied }
        return grants.removeFirst()
    }
}
actor RepairInstaller: AppSignInRepairInstalling {
    var failure: AppSignInDestination?
    var destinations: [AppSignInDestination] = []
    init(failure: AppSignInDestination? = nil) { self.failure = failure }
    func setFailure(_ failure: AppSignInDestination?) { self.failure = failure }
    func install(_ signIn: CodexSignIn, for profile: PlusProfile, destination: AppSignInDestination) async throws {
        if failure == destination { throw CodexSignInError.unavailable }
        destinations.append(destination)
    }
}
actor RepairCompletions {
    var destinations: [AppSignInDestination] = []
    func append(_ value: AppSignInRepairCompletion) { destinations.append(value.destination) }
}

@MainActor struct AppSignInRepairControllerTests {
    @Test func repairDrainsQueuedRefreshesWithoutStrandingLoadingRows() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let profiles = (0..<5).map { _ in CodexSignInFixture.profile() }
        try f.store.saveProfiles(profiles)
        let barrier = SyncBarrier(), data = SyncControllerDataService()
        data.refreshBarrier = barrier
        data.holdFirstRefreshOnly = true
        let identity = try CodexSignIn(data: CodexSignInFixture.data()).identity
        let controller = PlusProfileController(catalogStore: f.store, dataService: data,
            repairService: RepairControllerService(identity: identity), syncDefaults: f.defaults, autoStart: false)
        let refresh = Task { await controller.refreshAll() }
        await barrier.started()
        data.refreshBarrier = nil
        let repair = Task { await controller.repairBothSignIns(profileID: profiles[0].id) }
        // Begin repair synchronously on the main actor before releasing refresh.
        while controller.appSignInRepairProgress == nil { await Task.yield() }
        await barrier.release(); await refresh.value; await repair.value
        #expect(!controller.isRefreshing)
        #expect(controller.profiles.allSatisfy { !$0.isRefreshing })
    }

    @Test func repairUpdatesBothBindingsAndClearsOnlySuccessfulWarnings() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let profile = CodexSignInFixture.profile(); try f.store.saveProfiles([profile])
        let signIn = try CodexSignIn(data: CodexSignInFixture.data())
        let service = RepairControllerService(identity: signIn.identity)
        let controller = PlusProfileController(catalogStore: f.store, dataService: SyncControllerDataService(),
            repairService: service, syncDefaults: f.defaults, autoStart: false)
        await controller.repairBothSignIns(profileID: profile.id)
        let saved = try #require(f.store.loadProfiles().first)
        #expect(saved.codexSignIn == signIn.identity)
        #expect(saved.openCodeOpenAIAccount?.accountID == signIn.identity.accountID)
        #expect(saved.currentOpenChamberSignInCheck?.outcome == .verified)
        #expect(controller.appSignInRepairStatus?.message == "Both app sign-ins updated.")
        #expect(controller.appSignInRepairProgress == nil)
    }

    @Test func partialRepairAndCancelKeepCompletedDesktopAndBlockCompetingActions() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let profile = CodexSignInFixture.profile(); try f.store.saveProfiles([profile])
        let signIn = try CodexSignIn(data: CodexSignInFixture.data()), barrier = SyncBarrier()
        let service = RepairControllerService(identity: signIn.identity, barrier: barrier)
        let controller = PlusProfileController(catalogStore: f.store, dataService: SyncControllerDataService(),
            repairService: service, syncDefaults: f.defaults, autoStart: false)
        let task = Task { await controller.repairBothSignIns(profileID: profile.id) }
        await barrier.started()
        #expect(!controller.canCheckOpenChamberSignIns)
        await controller.removeProfile(id: profile.id)
        await controller.saveDesktopSignIn(profileID: profile.id)
        #expect(controller.desktopSignInStatus == nil)
        await controller.repairBothSignIns(profileID: profile.id)
        controller.cancelAppSignInRepair()
        await barrier.release(); await task.value
        let saved = try #require(f.store.loadProfiles().first)
        #expect(saved.codexSignIn == signIn.identity)
        #expect(saved.openCodeOpenAIAccount == nil)
        #expect(controller.appSignInRepairStatus?.message.contains("ChatGPT / Codex updated") == true)
        #expect(await service.calls == 1)
    }
}

actor RepairControllerService: AppSignInRepairing {
    let identity: CodexSignInIdentity
    let barrier: SyncBarrier?
    var calls = 0
    init(identity: CodexSignInIdentity, barrier: SyncBarrier? = nil) { self.identity = identity; self.barrier = barrier }
    func repair(profile: PlusProfile, openURL: @escaping @Sendable (URL) async throws -> Void,
                progress: @escaping @Sendable (AppSignInRepairProgress) async -> Void,
                completed: @escaping @Sendable (AppSignInRepairCompletion) async throws -> Void,
                isCurrent: @escaping @Sendable () async -> Bool) async throws {
        calls += 1
        #expect(await isCurrent())
        try await completed(.init(destination: .desktop, identity: identity))
        if let barrier { await barrier.wait() }
        try Task.checkCancellation()
        #expect(await isCurrent())
        try await completed(.init(destination: .openChamber, identity: identity))
    }
}

private struct RepairRotationVerifier: OpenCodeOpenAICredentialVerifying {
    let fresh: OpenCodeOpenAIAuth
    let barrier: SyncBarrier?
    func verify(_ auth: OpenCodeOpenAIAuth) async throws {
        if auth.refresh == "receipt-a" { throw OpenCodeOpenAIVerificationError.unauthorized }
    }
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth {
        guard auth.refresh == "native-b" else { throw OpenCodeOpenAIVerificationError.reauthenticationRequired }
        if let barrier { await barrier.wait() }
        return fresh
    }
}

private struct RepairDesktopInstaller: AppSignInRepairInstalling {
    let desktop: CodexAccountSwitchService
    func install(_ signIn: CodexSignIn, for profile: PlusProfile, destination: AppSignInDestination) async throws {
        if destination == .desktop { try await desktop.installRepaired(signIn, for: profile) }
    }
}
