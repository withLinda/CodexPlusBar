import Foundation
import Testing
@testable import CodexPlusBar

@MainActor struct CloudSyncPresentationTests {
    @Test func lastSuccessSurvivesDisableAndPendingNeverLooksCurrent() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let view = CloudSyncPresentation(coordinator: f.coordinator), date = Date(timeIntervalSince1970: 123_456)
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        try await f.journal.transaction { state in
            state.lastSuccess = date
            state.transport?.blockedRecords["session-broken"] = .invalid
        }
        await f.coordinator.syncNow()
        #expect(view.status != .upToDate)
        #expect(view.lastSuccessfulSync == date)
        await f.coordinator.setEnabled(false)
        #expect(view.status == .off)
        #expect(view.lastSuccessfulSync == date)
        f.currentOwner = .init(container: f.owner.container, environment: f.owner.environment, userRecordName: "another-owner")
        await f.coordinator.setEnabled(true)
        #expect(view.lastSuccessfulSync == nil)
        await f.coordinator.stop()
    }

    @Test func changingSelectionDuringImportCancelsInstallationAndFeedback() async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key()), f = try SessionFixture(inboxKeys: keys)
        defer { f.clean() }
        let barrier = SyncBarrier()
        let native = try NativeSwitchFixture(verifier: AdoptionDesktopVerifier(verify: { _ in await barrier.wait() }))
        defer { native.cleanUp() }
        f.nativeAdoption = { .init(authorization: $0, desktop: native.service) }
        let view = CloudSyncPresentation(coordinator: f.coordinator)
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let login = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        _ = try await receiveAdoption(.desktop(signIn: login, consumed: []), in: f, keys: keys)
        await view.selectProfile(f.profile.id)
        let summary = try #require(view.sessions.first)
        let task = Task { try await view.adopt(summary) }
        await barrier.started()
        await view.selectProfile(UUID())
        await barrier.release()
        _ = await task.result
        #expect(!FileManager.default.fileExists(atPath: native.vault.url(for: login.identity).path))
        #expect(view.failure == nil && view.sessionMessage == nil && !view.canRetry)
        await f.coordinator.stop()
    }

    @Test func errorGuidanceSeparatesNetworkKeychainAndRepair() {
        #expect(CloudSyncIssue(URLError(.timedOut)) == .network)
        #expect(CloudSyncIssue(CloudKeyStoreError.waitingForKey(UUID())) == .keychain)
        #expect(CloudSyncIssue(CodexSignInError.unauthorized) == .repair)
        #expect(CloudSyncIssue(OpenCodeOpenAIVerificationError.reauthenticationRequired) == .repair)
        #expect(CloudSyncIssue(CloudTransportError.accountChanged) == .account)
    }

    @Test func retryRetainsExactRequestAndRejectsChangedOwner() async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key()), f = try SessionFixture(inboxKeys: keys)
        defer { f.clean() }
        let verifier = AdoptionDesktopVerifier(verify: { _ in throw URLError(.timedOut) })
        let native = try NativeSwitchFixture(verifier: verifier); defer { native.cleanUp() }
        f.nativeAdoption = { .init(authorization: $0, desktop: native.service) }
        let view = CloudSyncPresentation(coordinator: f.coordinator)
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let login = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        _ = try await receiveAdoption(.desktop(signIn: login, consumed: []), in: f, keys: keys)
        await view.selectProfile(f.profile.id)
        let summary = try #require(view.sessions.first)
        await #expect(throws: URLError.self) { try await view.adopt(summary) }
        #expect(view.canRetry)
        #expect(view.failure == .network)
        let recovered = try NativeSwitchFixture(home: native.home)
        f.nativeAdoption = { .init(authorization: $0, desktop: recovered.service) }
        try await view.retry()
        #expect(try native.vault.load(login.identity) == login)
        #expect(!view.canRetry)
        f.currentOwner = .init(container: f.owner.container, environment: f.owner.environment, userRecordName: "other")
        await f.coordinator.setEnabled(false)
        await f.coordinator.setEnabled(true)
        await #expect(throws: CloudSessionError.unavailable) { try await view.adopt(summary) }
        await f.coordinator.stop()
    }

    @Test func optInAndSavedSessionChoiceFollowCoordinatorAndTransferGate() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let view = CloudSyncPresentation(coordinator: f.coordinator)
        #expect(!view.enabled)
        #expect(view.includesSessions)
        #expect(!view.canSyncNow)
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        #expect(view.enabled)
        #expect(view.canSyncNow)
        await f.coordinator.setIncludesSessions(false)
        #expect(!view.includesSessions)
        try await f.coordinator.pauseForTransfer(restoring: true)
        #expect(!view.canSyncNow)
        try f.coordinator.markRestoreCommitAttempt()
        await f.coordinator.resumeAfterTransfer(restored: true)
        #expect(!view.canSyncNow)
        await f.coordinator.setEnabled(false)
        #expect(!view.enabled)
        await f.coordinator.stop()
    }

    @Test func onlySelectedExactInboxRevisionCanBeAdopted() async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key()), f = try SessionFixture(inboxKeys: keys)
        defer { f.clean() }
        let native = try NativeSwitchFixture(); defer { native.cleanUp() }
        f.nativeAdoption = { .init(authorization: $0, desktop: native.service) }
        let view = CloudSyncPresentation(coordinator: f.coordinator)
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let login = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        _ = try await receiveAdoption(.desktop(signIn: login, consumed: []), in: f, keys: keys)
        await view.selectProfile(f.profile.id)
        let summary = try #require(view.sessions.first)
        f.profiles.setCloudDraftOwner(f.profile.id)
        #expect(!view.canAdopt(summary))
        f.profiles.setCloudDraftOwner(nil)
        await view.selectProfile(UUID())
        await #expect(throws: CloudSessionError.unavailable) { try await view.adopt(summary) }
        #expect(!FileManager.default.fileExists(atPath: native.vault.url(for: login.identity).path))
        await view.selectProfile(f.profile.id)
        try await view.adopt(summary)
        #expect(try native.vault.load(login.identity) == login)
        await f.coordinator.stop()
    }
}
