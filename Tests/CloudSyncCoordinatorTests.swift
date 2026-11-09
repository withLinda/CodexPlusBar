import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor struct CloudSyncCoordinatorTests {
    @Test func failedDeletionAdmissionRetriesBeforeAdvancingBaseline() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let fault = CoordinatorJournalFault()
        let journal = CloudSyncJournal(root: f.cloud, owner: f.owner, io: .init { event, name in
            if name == "journal.json", event == .rename, fault.enabled { throw POSIXError(.EIO) }
        })
        let bridge = CloudCatalogBridge(profiles: f.profiles, journal: journal, deviceID: UUID(), epoch: UUID())
        try bridge.reconcileLocal(inferDeletions: false); bridge.attach()
        fault.enabled = true
        await f.profiles.removeProfile(id: local.id)
        #expect(try f.store.loadProfiles().isEmpty)
        #expect(bridge.failure != nil)
        fault.enabled = false
        try bridge.reconcileLocal(inferDeletions: false)
        #expect(try journal.catalogState().profiles[CloudJournalState.profileRecordName(local.id)]?.tombstone != nil)
        #expect(bridge.failure == nil)
        bridge.stop()
    }

    @Test func syncNowRecoversFailedCatalogWriteWithoutRestart() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        try await f.stage(.init(id: local.id, createdAt: local.createdAt,
            fields: .init(label: .init(value: "retry remote", version: .init(counter: 100, deviceID: UUID())))), journal: f.journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.path)
        await coordinator.syncNow()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
        #expect(try f.journal.catalogState().receipts.values.contains { $0.phase == .applying })
        await coordinator.syncNow()
        #expect(try f.store.loadProfiles().first?.label == "retry remote")
        #expect(try f.journal.catalogState().receipts.values.allSatisfy { $0.phase == .applied })
        await coordinator.stop()
    }

    @Test func draftDeferredRestoreBlocksEditsAndRetriesSameRemap() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        try await coordinator.pauseForTransfer(restoring: true)
        try coordinator.markRestoreCommitAttempt()
        await coordinator.resumeAfterTransfer(restored: true)
        f.profiles.setCloudDraftOwner(local.id)
        f.transport.fetch = { journal in
            try await f.stage(.init(id: local.id, createdAt: local.createdAt,
                tombstone: .init(version: .init(counter: 100, deviceID: UUID()), deletedAt: .now)), journal: journal)
        }
        await coordinator.setEnabled(true)
        let mapped = try #require(try f.journal.catalogState().restoreProfileRemap?[local.id])
        var draft = PlusProfileDetailsDraft(profile: local); draft.notes = "must wait"
        #expect(!f.profiles.updateDetails(for: local.id, draft: draft, base: .init(profile: local)))
        f.profiles.setCloudDraftOwner(nil)
        await coordinator.syncNow()
        #expect(try f.store.loadProfiles().first?.id == mapped)
        #expect(try f.journal.catalogState().restoreIntent == nil)
        #expect(try f.preferences.read()?.preferences.paused == false)
        await coordinator.stop()
    }

    @Test func restoredRemapStillRetriesAfterRestartAndStoppedBridgeRejectsEdits() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        try await coordinator.pauseForTransfer(restoring: true)
        try coordinator.markRestoreCommitAttempt()
        await coordinator.resumeAfterTransfer(restored: true)
        f.profiles.setCloudDraftOwner(local.id)
        f.transport.fetch = { journal in
            try await f.stage(.init(id: local.id, createdAt: local.createdAt,
                tombstone: .init(version: .init(counter: 100, deviceID: UUID()), deletedAt: .now)), journal: journal)
        }
        await coordinator.setEnabled(true)
        let mapped = try #require(try f.journal.catalogState().restoreProfileRemap?[local.id])
        await coordinator.stop()
        var draft = PlusProfileDetailsDraft(profile: local); draft.notes = "blocked after stop"
        #expect(!f.profiles.updateDetails(for: local.id, draft: draft, base: .init(profile: local)))
        let restarted = f.coordinator()
        await restarted.start(); await restarted.setEnabled(true)
        #expect(restarted.isEnabled)
        #expect(restarted.status == .pending)
        f.profiles.setCloudDraftOwner(nil)
        await restarted.syncNow()
        #expect(try f.store.loadProfiles().first?.id == mapped)
        #expect(try f.journal.catalogState().restoreIntent == nil)
        await restarted.stop()
    }

    @Test(arguments: [false, true])
    func freshMissingCatalogDownloadsButMissingCommittedCatalogFailsClosed(startupChromeScaffold: Bool) async throws {
        let f = try CloudCoordinatorFixture(fresh: true); defer { f.clean() }
        if startupChromeScaffold {
            _ = try ChromeProfileStore(rootDirectory: f.root.appendingPathComponent("ChromeProfiles")).migrateAndPrune(profiles: [])
        }
        let remote = backupTestProfile()
        let coordinator = f.coordinator()
        f.transport.fetch = { journal in
            try await f.stage(.init(id: remote.id, createdAt: remote.createdAt,
                fields: .init(values: CloudProfileProjection.values(from: remote), version: .init(counter: 1, deviceID: UUID()))), journal: journal)
        }
        await coordinator.start(); await coordinator.setEnabled(true)
        try #require(try f.store.loadProfiles().map(\.id) == [remote.id])
        await coordinator.stop()
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("profiles.json"))
        f.reload()
        let restarted = f.coordinator()
        await restarted.start()
        #expect(restarted.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("profiles.json").path))
        await restarted.stop()
    }

    @Test func repeatedCatalogRevisionsRetainOnlyCurrentRecoveryPayload() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        let pending = try await f.journal.receive(recordName: "profile.pending", ciphertext: Data([7]), transportManaged: true)
        let session = try await f.journal.receive(recordName: "session.pending", ciphertext: Data([8]), transportManaged: true)
        for counter in 100...115 {
            try await f.stage(.init(id: local.id, createdAt: local.createdAt,
                fields: .init(notes: .init(value: String(repeating: "x", count: 2048) + "\(counter)",
                    version: .init(counter: UInt64(counter), deviceID: UUID())))), journal: f.journal)
            await coordinator.syncNow()
        }
        let state = try f.journal.catalogState()
        #expect(state.receipts.count <= 3)
        #expect(state.receipts.values.compactMap(\.plan).isEmpty)
        #expect(state.receivedEnvelopes.count == 2)
        #expect(state.transport?.inboxOrder.count == 2)
        #expect(state.completedCatalogReceipts?.count == 1)
        #expect(try CloudJournalCoding.encode(state).count < 20_000)
        #expect(try await f.journal.ciphertext(for: pending.id) == Data([7]))
        #expect(try await f.journal.ciphertext(for: session.id) == Data([8]))
        let assets = try FileManager.default.contentsOfDirectory(at: CloudSyncPaths(root: f.cloud).partition(for: f.owner).appendingPathComponent("inbox"), includingPropertiesForKeys: nil)
        #expect(assets.filter { $0.pathExtension == "asset" }.count == 2)
        await coordinator.stop()
    }

    @Test(arguments: [false, true], [false, true])
    func cloudRemovalKeepsNativeActiveAcrossAutomaticPassesAndRestart(onlyActive: Bool, bound: Bool) async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let active = try nativeCredential("cloud-active", active: true), other = try nativeCredential("cloud-other")
        let client = SyncTestClient(onlyActive ? [active] : [active, other])
        func service() -> OpenChamberSyncService {
            .init(resolveClient: { client }, gate: .init(), snapshots: .init(homeDirectory: f.root),
                stateStore: .init(fileURL: f.root.appendingPathComponent("native-state.json")), verifier: SyncTestVerifier(),
                selector: SelectorControlClient(homeDirectory: f.root, connectionRefused: { true }))
        }
        var original = try syncProfile(active)
        if !bound { original.openCodeOpenAIAccount = nil }
        let retained = try syncProfile(other)
        try f.store.saveProfiles(onlyActive ? [original] : [original, retained])
        f.defaults.set(true, forKey: OpenChamberSyncPreference.enabledKey)
        f.reload(syncService: service())
        await f.profiles.prepareCloudCatalogApply()
        let removed = try f.profiles.applyCloudCatalog(CloudCatalogBridge.projection(onlyActive ? [] : [retained]))
        await f.profiles.finishCloudCatalogApply(removed: removed)
        await f.profiles.syncOpenChamberNow()
        f.reload(syncService: service())
        await f.profiles.syncOpenChamberNow()
        #expect(await client.inventory().openAI.first(where: \.active)?.id == active.id)
        #expect(await client.operations.allSatisfy { !$0.hasPrefix("activate:") && !$0.hasPrefix("remove:") })
        if !onlyActive {
            // Explicit native selection still permits subsequent inactive cleanup.
            await client.activate(id: other.id)
            await f.profiles.syncOpenChamberNow()
            #expect(await client.inventory().openAI.map(\.id) == [other.id])
        } else {
            // Re-linking and explicitly removing the native account is still allowed.
            let linked = try syncProfile(active)
            try f.store.saveProfiles([linked]); f.reload(syncService: service())
            await f.profiles.removeProfile(id: linked.id)
            await f.profiles.syncOpenChamberNow()
            #expect(await client.inventory().openAI.isEmpty)
        }
    }

    @Test func restoreUnionWaitsForUnknownCatalogCiphertextBeforeReusingUUIDs() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        try await coordinator.pauseForTransfer(restoring: true)
        try coordinator.markRestoreCommitAttempt()
        await coordinator.resumeAfterTransfer(restored: true)
        _ = try await f.journal.receive(recordName: CloudJournalState.profileRecordName(local.id), ciphertext: Data([8]), transportManaged: true)
        await coordinator.setEnabled(true)
        #expect(coordinator.status == .pending)
        #expect(try f.preferences.read()?.preferences.paused == true)
        #expect(try f.journal.catalogState().transport?.catalogPublicationPaused == true)
        #expect(try f.store.loadProfiles().first?.id == local.id)
        await coordinator.stop()
    }

    @Test func rejectedDiskSaveDoesNotQueueOrSendAnUncommittedEdit() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        try f.journal.catalogTransaction { state in
            for name in Array(state.dirtyGenerations.keys) {
                if let revision = state.sentRevision(for: name) { state.acknowledge(revision) }
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path) }
        var draft = PlusProfileDetailsDraft(profile: local); draft.notes = "uncommitted edit"
        #expect(!f.profiles.updateDetails(for: local.id, draft: draft, base: .init(profile: local)))
        await coordinator.syncNow()
        #expect(f.transport.sentRecords.isEmpty)
        #expect(try f.store.loadProfiles().first?.notes == local.notes)
        await coordinator.stop()
    }

    @Test func initialFetchRestartRetainsDraftDiffBaselineAndDoesNotReplaceFetchedFields() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        f.transport.fetch = { journal in
            let remote = CloudProfileDocument(id: local.id, createdAt: local.createdAt,
                fields: .init(label: .init(value: "remote before crash", version: .init(counter: 1, deviceID: UUID()))))
            try await f.stage(remote, journal: journal)
            var draft = PlusProfileDetailsDraft(profile: local); draft.notes = "saved while fetching"
            #expect(f.profiles.updateDetails(for: local.id, draft: draft, base: .init(profile: local)))
            throw URLError(.networkConnectionLost)
        }
        await coordinator.start(); await coordinator.setEnabled(true)
        #expect(coordinator.status == .failed)
        #expect(try f.journal.catalogState().initialCatalogProjection != nil)
        await coordinator.stop()
        let restarted = f.coordinator()
        await restarted.start()
        let row = try #require(try f.store.loadProfiles().first)
        #expect(row.label == "remote before crash")
        #expect(row.notes == "saved while fetching")
        #expect(try f.journal.catalogState().initialCatalogProjection == nil)
        await restarted.stop()
    }

    @Test func disableWhileReenableDrainsOldEngineCannotBeUndoneBySuspendedEnable() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        var release: CheckedContinuation<Void, Never>?
        f.transport.stopAction = { await withCheckedContinuation { release = $0 } }
        let reenabling = Task { await coordinator.setEnabled(true) }
        while release == nil { await Task.yield() }
        await coordinator.setEnabled(false)
        release?.resume()
        await reenabling.value
        #expect(!coordinator.isEnabled)
        #expect(f.transport.starts == 1)
        #expect(try f.preferences.read()?.preferences.enabled == false)
    }

    @Test func firstEnableDoesNotVersionLocalCopyBeforeCompleteFetchOrReplaceExistingRemoteField() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        f.transport.fetch = { journal in
            #expect(try journal.catalogState().dirtyGenerations.isEmpty)
            let remote = CloudProfileDocument(id: local.id, createdAt: local.createdAt,
                fields: .init(label: .init(value: "existing low-clock remote", version: .init(counter: 1, deviceID: UUID()))))
            try await f.stage(remote, journal: journal)
        }
        await coordinator.start(); await coordinator.setEnabled(true)
        #expect(try f.store.loadProfiles().first?.label == "existing low-clock remote")
        await coordinator.stop()
    }

    @Test func actualEncryptedRestoreControllerPersistsPauseBeforeTreeSwap() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let original = try #require(try f.store.loadProfiles().first)
        let service = BackupService(root: f.root)
        let archive = f.root.deletingLastPathComponent().appendingPathComponent("restore-test-\(UUID()).backup")
        defer { try? FileManager.default.removeItem(at: archive) }
        try await service.export(to: archive, password: "synthetic restore password",
            manifest: .init(profileCount: 1, preferences: BackupSessionBridge.preferences(in: f.defaults), cookies: [:]))
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        try await f.stage(.init(id: original.id, createdAt: original.createdAt,
            fields: .init(label: .init(value: "outstanding before restore", version: .init(counter: 100, deviceID: UUID())))), journal: f.journal)
        let recovery = CloudCatalogBridge(profiles: f.profiles, journal: f.journal,
            deviceID: try #require(try f.preferences.read()).deviceID, epoch: UUID())
        try recovery.prepareNextReceipt()
        #expect(try f.journal.catalogState().receipts.values.contains { $0.phase == .applying })
        let transfer = BackupTransferController(profiles: f.profiles,
            email: DotTrickController(store: .init(fileURL: f.root.appendingPathComponent("dot-trick-sessions.json"))),
            root: f.root, cloudSync: coordinator, defaults: f.defaults)
        transfer.mode = .restore; transfer.sourceURL = archive; transfer.password = "synthetic restore password"
        transfer.submitPassword()
        while transfer.isBusy { await Task.yield() }
        try #require(transfer.prepared != nil)
        transfer.restoreBackup()
        while transfer.isBusy { await Task.yield() }
        #expect({ if case .restored = transfer.phase { true } else { false } }())
        #expect(coordinator.status == .paused)
        let saved = try #require(try f.preferences.read())
        #expect(saved.preferences.transferPause?.phase == .commitAttempted)
        #expect(try f.journal.catalogState().restoreIntent != nil)
        let restored = try #require(try f.store.loadProfiles().first)
        #expect(restored.id == original.id)
        #expect(restored.webDataStoreID != original.webDataStoreID)
        #expect(try f.journal.catalogState().receipts.values.allSatisfy { $0.phase == .applied })
        await coordinator.setEnabled(true)
        #expect(coordinator.status != .failed)
        #expect(try f.journal.catalogState().restoreIntent == nil)
        await coordinator.stop()
        f.profiles.stopBackgroundTasks()
        _ = BackupSessionBridge.takeRestoredStore(for: restored.webDataStoreID)
        try? await WKWebsiteDataStore.remove(forIdentifier: original.webDataStoreID)
        try? await WKWebsiteDataStore.remove(forIdentifier: restored.webDataStoreID)
    }

    @Test func disableDuringFetchRejectsLateApplyAndConcurrentSyncNowCoalesces() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let original = try f.store.loadProfiles()
        let coordinator = f.coordinator()
        var release: CheckedContinuation<Void, Never>?
        f.transport.fetch = { _ in await withCheckedContinuation { release = $0 } }
        await coordinator.start()
        let enabling = Task { await coordinator.setEnabled(true) }
        while release == nil { await Task.yield() }
        let first = Task { await coordinator.syncNow() }
        let second = Task { await coordinator.syncNow() }
        await Task.yield()
        #expect(f.transport.fetches == 1)
        await coordinator.setEnabled(false)
        release?.resume()
        await enabling.value; await first.value; await second.value
        #expect(f.transport.fetches == 1)
        #expect(!coordinator.isEnabled)
        #expect(coordinator.status == .off)
        #expect(try f.store.loadProfiles() == original)
        #expect(try f.preferences.read()?.preferences.enabled == false)
    }

    @Test func networkErrorAndOutstandingInboxCannotReportUpToDate() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        try f.journal.catalogTransaction { state in
            for name in Array(state.dirtyGenerations.keys) {
                if let revision = state.sentRevision(for: name) { state.acknowledge(revision) }
            }
        }
        await coordinator.syncNow()
        #expect(coordinator.status == .upToDate)
        f.transport.fetch = { _ in throw URLError(.notConnectedToInternet) }
        await coordinator.syncNow()
        #expect(coordinator.status == .failed)
        let epoch = try #require(coordinator.epoch)
        f.transport.emit(.init(owner: f.owner, epoch: epoch, value: .status(.upToDate)))
        await Task.yield(); await Task.yield()
        #expect(coordinator.status != .upToDate)
        _ = try await f.journal.receive(recordName: "session.synthetic", ciphertext: Data([1]), transportManaged: true)
        await coordinator.syncNow()
        #expect(coordinator.status == .pending)
        await coordinator.stop()
    }

    @Test func lateSessionCaptureAfterDeleteOrDisableCannotPublish() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        let local = try #require(try f.store.loadProfiles().first)
        let admission = try #require(coordinator.sessionAdmission(for: local.id))
        let document = CloudSessionDocument(profileID: local.id, sourceDeviceID: UUID(), sourceName: "synthetic",
            kind: .browser, revision: 1, capturedAt: .now, payload: Data([1]))
        try f.store.saveProfiles([])
        #expect(throws: (any Error).self) { try coordinator.commitCapturedSession(document, admission: admission) }
        try f.store.saveProfiles([local])
        await coordinator.setIncludesSessions(false)
        #expect(throws: (any Error).self) { try coordinator.commitCapturedSession(document, admission: admission) }
        #expect(try f.journal.catalogState().sessions.isEmpty)
        await coordinator.stop()
    }

    @Test func explicitRestoreReenableRemapsTombstoneAndPreservesLocalStoresAndBindings() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        var local = try #require(try f.store.loadProfiles().first)
        local.codexSignIn = .init(accountID: "synthetic-account", userID: "synthetic-user", email: "synthetic@example.test")
        try f.store.saveProfiles([local]); f.reload()
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        let admission = try #require(coordinator.sessionAdmission(for: local.id))
        let session = CloudSessionDocument(profileID: local.id, sourceDeviceID: UUID(), sourceName: "synthetic",
            kind: .desktop, revision: 1, capturedAt: .now, payload: Data([4, 5]))
        try coordinator.commitCapturedSession(session, admission: admission)
        try await coordinator.pauseForTransfer(restoring: true)
        try coordinator.markRestoreCommitAttempt()
        await coordinator.resumeAfterTransfer(restored: true)
        #expect(coordinator.status == .paused)
        let tombstone = CloudProfileDocument(id: local.id, createdAt: local.createdAt,
            tombstone: .init(version: .init(counter: 100, deviceID: UUID()), deletedAt: .now))
        f.transport.fetch = { journal in try await f.stage(tombstone, journal: journal) }
        await coordinator.setEnabled(true)
        let restored = try #require(try f.store.loadProfiles().first)
        #expect(restored.id != local.id)
        #expect(restored.webDataStoreID == local.webDataStoreID)
        #expect(restored.codexSignIn == local.codexSignIn)
        #expect(try f.preferences.read()?.preferences.paused == false)
        #expect(try f.journal.catalogState().profiles[CloudJournalState.profileRecordName(local.id)]?.tombstone != nil)
        let state = try f.journal.catalogState()
        #expect(state.order?.ids == [restored.id])
        #expect(state.sessions.values.contains { $0.profileID == restored.id && $0.payload == session.payload })
        await coordinator.stop()
    }

    @Test func constructionOffAndUnavailableStartupHaveNoCloudOrDiskEffects() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let coordinator = f.coordinator(available: false)
        #expect(!FileManager.default.fileExists(atPath: f.cloud.path))
        await coordinator.start()
        await coordinator.setEnabled(true)
        #expect(f.identityReads == 0)
        #expect(f.transport.starts == 0)
        #expect(!FileManager.default.fileExists(atPath: f.cloud.path))
        let entitled = f.coordinator()
        await entitled.start()
        #expect(f.identityReads == 0)
        #expect(f.transport.sentRecords.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.cloud.path))
    }

    @Test func completeFetchUnionsInactiveProfilesAndLatestLocalEditBeforeApply() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        var local = backupTestProfile(); local.notes = "old local"
        var inactive = backupTestProfile(); inactive.provider = .init(rawValue: "retired")
        try f.store.saveProfiles([local, inactive]); f.reload()
        let coordinator = f.coordinator()
        let id = local.id
        f.transport.fetch = { journal in
            var draft = PlusProfileDetailsDraft(profile: local); draft.notes = "edited during fetch"
            #expect(f.profiles.updateDetails(for: id, draft: draft, base: .init(profile: local)))
            let remote = CloudProfileDocument(id: id, createdAt: local.createdAt,
                fields: .init(label: .init(value: "remote label", version: .init(counter: 20, deviceID: UUID()))))
            try await f.stage(remote, journal: journal)
        }
        await coordinator.start(); await coordinator.setEnabled(true)
        let rows = try f.store.loadProfiles()
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.id == id })?.notes == "edited during fetch")
        #expect(rows.first(where: { $0.id == id })?.label == "remote label")
        #expect(rows.first(where: { $0.id == id })?.webDataStoreID == local.webDataStoreID)
        #expect(rows.contains { $0.id == inactive.id && $0.provider == inactive.provider })
        #expect(try f.journal.catalogState().receipts.values.allSatisfy { $0.phase == .applied })
        await coordinator.stop()
    }

    @Test func rejectedSaveAndUnreadableCatalogPublishNothing() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        try Data("{broken".utf8).write(to: f.root.appendingPathComponent("profiles.json"))
        f.reload()
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        #expect(f.transport.sentRecords.isEmpty)
        #expect(f.transport.starts == 0)
        await coordinator.stop()
    }

    @Test func accountSwitchDisablesAcrossRestartAndOldEpochCannotApply() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        let oldEpoch = try #require(coordinator.epoch)
        f.owner = .init(container: f.owner.container, environment: .development, userRecordName: "new-owner")
        await coordinator.syncNow()
        #expect(!coordinator.isEnabled)
        f.transport.emit(.init(owner: CloudCoordinatorFixture.ownerA, epoch: oldEpoch, value: .status(.upToDate)))
        await Task.yield()
        #expect(coordinator.status != .upToDate)
        await coordinator.stop()
        let restarted = f.coordinator()
        let reads = f.identityReads
        await restarted.start()
        #expect(f.identityReads == reads)
        #expect(!restarted.isEnabled)
    }

    @Test func pendingReceiptReplaysOnRestartUsingMergedJournalNotRawEnvelope() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let device = try f.preferences.update { $0.setConsent(enabled: true, for: f.owner) }.deviceID
        try f.journal.catalogTransaction { try $0.reconcile(f.profiles.cloudCatalogRead(), deviceID: device) }
        let remote = CloudProfileDocument(id: local.id, createdAt: local.createdAt,
            fields: .init(label: .init(value: "latest merged", version: .init(counter: 25, deviceID: UUID()))))
        try await f.stage(remote, journal: f.journal)
        let bridge = CloudCatalogBridge(profiles: f.profiles, journal: f.journal, deviceID: device, epoch: UUID())
        try bridge.reconcileLocal(inferDeletions: false)
        try bridge.prepareNextReceipt()
        let state = try f.journal.catalogState()
        #expect(state.receipts.values.contains { $0.phase == .applying })
        let restarted = CloudCatalogBridge(profiles: f.profiles, journal: f.journal, deviceID: device, epoch: UUID())
        try restarted.replayPending()
        #expect(try f.store.loadProfiles().first?.label == "latest merged")
        #expect(try f.journal.catalogState().receipts.values.allSatisfy { $0.phase == .applied })
    }

    @Test func deletionDefersForOwnedDraftThenPreservesSelectionAndLocalNativeIdentity() async throws {
        let f = try CloudCoordinatorFixture(); defer { f.clean() }
        let local = try #require(try f.store.loadProfiles().first)
        let coordinator = f.coordinator()
        await coordinator.start(); await coordinator.setEnabled(true)
        f.profiles.setCloudDraftOwner(local.id)
        let deleted = CloudProfileDocument(id: local.id, createdAt: local.createdAt,
            tombstone: .init(version: .init(counter: 50, deviceID: UUID()), deletedAt: .now))
        try await f.stage(deleted, journal: f.journal)
        await coordinator.syncNow()
        #expect(try f.store.loadProfiles().contains { $0.id == local.id })
        #expect(coordinator.status != .upToDate)
        f.profiles.setCloudDraftOwner(nil)
        await coordinator.syncNow()
        #expect(try f.store.loadProfiles().isEmpty)
        await coordinator.stop()
    }
}

@MainActor private final class CloudCoordinatorFixture {
    static let ownerA = CloudOwner(container: "iCloud.com.linda.CodexPlusBar", environment: .development, userRecordName: "synthetic-A")
    let root: URL
    let cloud: URL
    let store: ProfileCatalogStore
    let preferences: CloudSyncPreferencesStore
    let journal: CloudSyncJournal
    var profiles: PlusProfileController
    var owner = ownerA
    var identityReads = 0
    let transport = CoordinatorTransport()
    let defaults: UserDefaults
    let suite = "CloudCoordinator.\(UUID())"
    init(fresh: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID())")
        cloud = root.deletingLastPathComponent().appendingPathComponent("cloud-coordinator-\(UUID())")
        store = .init(fileURL: root.appendingPathComponent("profiles.json"))
        if !fresh { try store.saveProfiles([backupTestProfile()]) }
        preferences = .init(root: cloud)
        journal = .init(root: cloud, owner: Self.ownerA)
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: OpenChamberSyncPreference.enabledKey)
        profiles = .init(catalogStore: store, dataService: CoordinatorDataService(), accountSwitchService: CoordinatorAccountSwitch(), syncDefaults: defaults, autoStart: false)
        transport.journal = journal
    }
    func reload(syncService: any OpenChamberSyncServing = OpenChamberSyncService()) {
        profiles.stopBackgroundTasks()
        profiles = .init(catalogStore: store, dataService: CoordinatorDataService(), accountSwitchService: CoordinatorAccountSwitch(),
            syncService: syncService, syncDefaults: defaults, autoStart: false)
    }
    func coordinator(available: Bool = true) -> CloudSyncCoordinator {
        .init(profiles: profiles, preferences: preferences, availability: { available ? .development : nil },
              identity: { [self] _ in identityReads += 1; return owner },
              makeTransport: { [self] _ in transport })
    }
    func clean() {
        profiles.stopBackgroundTasks(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cloud)
        try? FileManager.default.removeItem(at: store.nativeSelectionFile)
    }
    func stage(_ document: CloudProfileDocument, journal: CloudSyncJournal) async throws {
        let name = CloudJournalState.profileRecordName(document.id)
        let envelope = try await journal.receive(recordName: name, ciphertext: Data([1, 2]), transportManaged: true)
        try await journal.transaction {
            $0.profiles[name] = try $0.profiles[name].map { try CloudProfileMerge.merge($0, document) } ?? document
            $0.lamportCounter = max($0.lamportCounter, document.fields.versions.map(\.counter).max() ?? document.tombstone?.version.counter ?? 0)
            if $0.dirtyGenerations[name] != nil { try $0.markDirty(recordName: name, body: .profile($0.profiles[name]!)) }
            $0.transport?.processedInbox.insert(envelope.id)
        }
    }
}

private struct CoordinatorAccountSwitch: CodexAccountSwitchServing {
    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity { throw CocoaError(.featureUnsupported) }
    func switchAndOpen(profile: PlusProfile) async throws { throw CocoaError(.featureUnsupported) }
}

private final class CoordinatorJournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor private final class CoordinatorDataService: PlusProfileDataServing {
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult { throw ChatGPTAPIError.unauthorized }
    func openChromeAccountPage(for profile: PlusProfile) async throws {}
    func openChromeSignIn(for profile: PlusProfile) async throws {}
    func openChromePasskeySetup(for profile: PlusProfile) async throws {}
    func syncChromeSession(for profile: PlusProfile) async throws {}
    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool { false }
    func closeChromeSignIn(for profile: PlusProfile) async {}
    func clearSession(for profile: PlusProfile) async throws {}
    func removeProfileData(for profile: PlusProfile) async throws {}
}

@MainActor private final class CoordinatorTransport: CloudSyncTransport {
    nonisolated let events: AsyncStream<CloudTransportEvent>
    nonisolated let continuation: AsyncStream<CloudTransportEvent>.Continuation
    var starts = 0
    var fetches = 0
    var sentRecords: [String] = []
    var journal: CloudSyncJournal!
    var fetch: (@MainActor (CloudSyncJournal) async throws -> Void)?
    var stopAction: (@MainActor () async -> Void)?
    init() {
        let stream = AsyncStream<CloudTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = stream.stream; continuation = stream.continuation
    }
    func start(owner: CloudOwner, epoch: UUID) async throws { starts += 1 }
    func syncNow() async throws {
        fetches += 1
        let action = fetch; fetch = nil
        try await action?(journal)
        try await journal.transaction { if $0.transport == nil { $0.transport = .init() }; $0.transport?.initialized = true }
        sentRecords = Array(try await journal.load().dirtyGenerations.keys)
    }
    func stop() async { let action = stopAction; stopAction = nil; await action?() }
    func emit(_ event: CloudTransportEvent) { continuation.yield(event) }
}
