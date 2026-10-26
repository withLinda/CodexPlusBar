import Foundation
import Testing
@testable import CodexPlusBar

@MainActor
struct OpenChamberSyncControllerTests {
    @Test func missingCatalogIsNotIntentionalEmpty() throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        #expect(try f.store.loadProfilesWithReport().sourceExists == false)
        try f.store.saveProfiles([])
        #expect(try f.store.loadProfilesWithReport().sourceExists)
    }

    @Test func failedProfileSaveDoesNotAuthorizeRemoteDeletion() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let profile = try syncProfile(nativeCredential("alpha"))
        try f.store.saveProfiles([profile])
        let service = RecordingSyncService()
        let controller = f.controller(service)
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: true)
        await controller.removeProfile(id: profile.id)
        await controller.syncOpenChamberNow()
        #expect(controller.profiles.map(\.id) == [profile.id])
        #expect(await service.catalogs.isEmpty)
    }

    @Test func successfulRemovalSchedulesCommittedCatalog() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let a = try syncProfile(nativeCredential("alpha")), b = try syncProfile(nativeCredential("beta"))
        try f.store.saveProfiles([a, b])
        let service = RecordingSyncService(), controller = f.controller(service)
        await controller.removeProfile(id: a.id)
        await controller.syncOpenChamberNow()
        #expect(try f.store.loadProfiles().map(\.id) == [b.id])
        #expect(await service.catalogs.last?.profiles.map(\.id) == [b.id])
    }

    @Test func unrelatedProfileEditDuringRemovalIsPreserved() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let a = try syncProfile(nativeCredential("alpha")), b = try syncProfile(nativeCredential("beta"))
        try f.store.saveProfiles([a, b])
        let data = SyncControllerDataService(), barrier = SyncBarrier()
        data.removeBarrier = barrier
        let controller = f.controller(RecordingSyncService(), data: data)
        let remove = Task { await controller.removeProfile(id: a.id) }
        await barrier.started()
        controller.profiles.swapAt(0, 1)
        var draft = PlusProfileDetailsDraft(profile: b); draft.notes = "Edited during await"
        #expect(controller.updateDetails(for: b.id, draft: draft))
        await barrier.release(); await remove.value
        #expect(controller.profiles.map(\.id) == [b.id])
        #expect(controller.profiles.first?.profile.notes == "Edited during await")
    }

    @Test func refreshCompletingAfterRemovalCannotResurrectProfile() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let a = try syncProfile(nativeCredential("alpha")); try f.store.saveProfiles([a])
        let data = SyncControllerDataService(), barrier = SyncBarrier(); data.refreshBarrier = barrier
        let controller = f.controller(RecordingSyncService(), data: data)
        let refresh = Task { await controller.refreshProfile(id: a.id) }
        await barrier.started(); await controller.removeProfile(id: a.id); await barrier.release(); await refresh.value
        #expect(controller.profiles.isEmpty)
        #expect(try f.store.loadProfiles().isEmpty)
    }

    @Test func sameProfileRemovedTwiceDoesNotRemoveNeighbor() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let a = try syncProfile(nativeCredential("alpha")), b = try syncProfile(nativeCredential("beta"))
        try f.store.saveProfiles([a, b])
        let data = SyncControllerDataService(), barrier = SyncBarrier(); data.removeBarrier = barrier
        let controller = f.controller(RecordingSyncService(), data: data)
        let first = Task { await controller.removeProfile(id: a.id) }
        await barrier.started()
        await controller.removeProfile(id: a.id)
        await barrier.release(); await first.value
        #expect(controller.profiles.map(\.id) == [b.id])
    }

    @Test func manualActionWaitsForSyncCancellation() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let barrier = SyncBarrier(), service = RecordingSyncService(barrier: barrier)
        let scheduler = OpenChamberSyncScheduler(service: service, defaults: f.defaults)
        scheduler.update(profiles: [], trusted: true)
        let running = Task { await scheduler.syncNow() }
        await barrier.started()
        let pause = Task { await scheduler.pauseForManualOperation() }
        await Task.yield()
        await barrier.release(); await pause.value; await running.value
        #expect(await service.allowedAfterWait == false)
        #expect(scheduler.isSyncing == false)
        #expect(scheduler.result == nil)
    }

    @Test func deviceLoginSavePersistsBindingBeforeSync() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let entry = try nativeCredential("alpha"); var a = try syncProfile(entry); a.openCodeOpenAIAccount = nil
        try f.store.saveProfiles([a])
        let service = RecordingSyncService()
        let controller = f.controller(service, auth: CapturedSyncAuth(identity: try entry.openAIIdentity()))
        await controller.saveOpenChamberAuth(profileID: a.id)
        await controller.syncOpenChamberNow()
        #expect(try f.store.loadProfiles().first?.openCodeOpenAIAccount == entry.openAIIdentity())
        #expect(try await service.catalogs.last?.profiles.first?.openCodeOpenAIAccount == entry.openAIIdentity())
    }

    @Test func failedSaveLeavesPendingLoginUnpruned() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let entry = try nativeCredential("alpha"); var a = try syncProfile(entry); a.openCodeOpenAIAccount = nil
        try f.store.saveProfiles([a])
        let service = RecordingSyncService(), controller = f.controller(service, auth: CapturedSyncAuth(identity: try entry.openAIIdentity()))
        try FileManager.default.removeItem(at: f.file); try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: true)
        await controller.saveOpenChamberAuth(profileID: a.id); await controller.syncOpenChamberNow()
        #expect(controller.profiles.first?.profile.openCodeOpenAIAccount == nil)
        #expect(await service.catalogs.isEmpty)
    }

    @Test func disablingStopsNextMutationAndClearsStaleSuccess() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let barrier = SyncBarrier(), service = RecordingSyncService(barrier: barrier)
        let scheduler = OpenChamberSyncScheduler(service: service, defaults: f.defaults)
        scheduler.update(profiles: [], trusted: true)
        let operation = Task { await scheduler.syncNow() }
        await barrier.started()
        f.defaults.set(false, forKey: OpenChamberSyncPreference.enabledKey)
        scheduler.preferenceChanged()
        await barrier.release(); await operation.value
        #expect(scheduler.result == nil)
        #expect(await service.allowedAfterWait == false)
    }

    @Test func rapidEditsCoalesceAfterOneSecond() async throws {
        let f = ControllerSyncFixture(); defer { f.remove() }
        let clock = SyncTestClock(), service = RecordingSyncService()
        let scheduler = OpenChamberSyncScheduler(service: service, defaults: f.defaults, sleep: { try await clock.sleep($0) })
        scheduler.update(profiles: [], trusted: true); scheduler.start()
        await scheduler.syncNow()
        let before = await service.catalogs.count
        let a = try syncProfile(nativeCredential("alpha")), b = try syncProfile(nativeCredential("beta"))
        scheduler.update(profiles: [a], trusted: true)
        scheduler.update(profiles: [a, b], trusted: true)
        await clock.waitFor(interval: 1)
        #expect(await service.catalogs.count == before)
        await clock.advance(interval: 1)
        await service.waitFor(count: before + 1)
        #expect(await service.catalogs.last?.profiles.count == 2)
        await clock.waitFor(interval: 60)
        await clock.advance(interval: 60)
        await service.waitFor(count: before + 2)
        scheduler.stop()
    }
}

@MainActor
struct ControllerSyncFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "SyncTests." + UUID().uuidString
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var file: URL { directory.appendingPathComponent("profiles.json") }
    var store: ProfileCatalogStore { .init(fileURL: file) }
    func remove() { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
    func controller(_ service: RecordingSyncService, data: SyncControllerDataService = .init(), auth: (any OpenCodeOpenAIAuthServing)? = nil) -> PlusProfileController {
        PlusProfileController(catalogStore: store, dataService: data,
                              openCodeAuthService: auth ?? OpenCodeOpenAIAuthService(), syncService: service, syncDefaults: defaults, autoStart: false)
    }
}

actor RecordingSyncService: OpenChamberSyncServing {
    var catalogs: [OpenChamberSyncCatalog] = []
    var allowedAfterWait = true
    let barrier: SyncBarrier?
    var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    init(barrier: SyncBarrier? = nil) { self.barrier = barrier }
    func reconcile(catalog: OpenChamberSyncCatalog, isCurrent: @escaping @Sendable (UInt64) async -> Bool) async throws -> OpenChamberSyncResult {
        catalogs.append(catalog)
        for (count, continuation) in waiting where catalogs.count >= count { continuation.resume() }
        waiting.removeAll { catalogs.count >= $0.0 }
        if let barrier { await barrier.wait() }
        allowedAfterWait = await isCurrent(catalog.generation)
        guard allowedAfterWait else { throw OpenChamberSyncError.changed }
        return .init(matchedCount: 0, totalCount: catalog.profiles.count, needsSignInProfileIDs: [], pendingCredentialCount: 0, deferredActiveRemoval: false)
    }
    func waitFor(count: Int) async { if catalogs.count < count { await withCheckedContinuation { waiting.append((count, $0)) } } }
}

struct CapturedSyncAuth: OpenCodeOpenAIAuthServing {
    let identity: OpenCodeOpenAIIdentity
    func saveCurrent(for profile: PlusProfile) async throws -> OpenCodeOpenAIIdentity { identity }
    func switchTo(profile: PlusProfile) async throws {}
}

@MainActor
final class SyncControllerDataService: PlusProfileDataServing {
    var removeBarrier: SyncBarrier?
    var refreshBarrier: SyncBarrier?
    func removeProfileData(for profile: PlusProfile) async throws { if let removeBarrier { await removeBarrier.wait() } }
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        if let refreshBarrier { await refreshBarrier.wait() }
        throw ChatGPTAPIError.unauthorized
    }
    func openChromeSignIn(for profile: PlusProfile) async throws {}
    func openChromeAccountPage(for profile: PlusProfile) async throws {}
    func openChromePasskeySetup(for profile: PlusProfile) async throws {}
    func syncChromeSession(for profile: PlusProfile) async throws {}
    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool { false }
    func closeChromeSignIn(for profile: PlusProfile) async {}
    func clearSession(for profile: PlusProfile) async throws {}
}

actor SyncTestClock {
    var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
    var watchers: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (interval, continuation)
                for (target, watcher) in watchers where target == interval { watcher.resume() }
                watchers.removeAll { $0.0 == interval }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func cancel(_ id: UUID) { sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    func waitFor(interval: TimeInterval) async {
        if !sleepers.values.contains(where: { $0.0 == interval }) { await withCheckedContinuation { watchers.append((interval, $0)) } }
    }
    func advance(interval: TimeInterval) {
        for id in sleepers.keys.filter({ sleepers[$0]?.0 == interval }) { sleepers.removeValue(forKey: id)?.1.resume() }
    }
}
