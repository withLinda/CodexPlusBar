import CloudKit
import Foundation
import Observation

enum CloudSyncStatus: Equatable { case off, unavailable, needsConsent, syncing, upToDate, paused, pending, failed }

struct CloudSessionAdmission: Sendable {
    let owner: CloudOwner
    let epoch: UUID
    let profileID: UUID
}

@Observable @MainActor final class CloudSyncCoordinator {
    private(set) var status: CloudSyncStatus = .off
    private(set) var isEnabled = false
    private(set) var includesSessions = true
    private(set) var deliveryDegraded = false
    private(set) var epoch: UUID?
    private(set) var owner: CloudOwner?
    @ObservationIgnored private let profiles: PlusProfileController
    @ObservationIgnored let preferences: CloudSyncPreferencesStore
    @ObservationIgnored private let availability: @MainActor () -> CloudEnvironment?
    @ObservationIgnored private let identity: @MainActor (CloudEnvironment) async throws -> CloudOwner
    @ObservationIgnored private let makeTransport: @MainActor (CloudSyncJournal) -> any CloudSyncTransport
    @ObservationIgnored private var transport: (any CloudSyncTransport)?
    @ObservationIgnored private var bridge: CloudCatalogBridge?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var intent = UUID()
    @ObservationIgnored private var needsInitialUnion = true
    @ObservationIgnored private var verifiedPass = false
    @ObservationIgnored private var restoringUnion = false
    @ObservationIgnored private var pausedJournal: CloudSyncJournal?

    init(profiles: PlusProfileController, preferences: CloudSyncPreferencesStore = .init(),
         availability: @escaping @MainActor () -> CloudEnvironment? = { CloudSyncAvailability().environment },
         identity: @escaping @MainActor (CloudEnvironment) async throws -> CloudOwner = { environment in
             let container = try CloudSyncAvailability().withContainer(environment: environment) { CKContainer(identifier: $0) }
             guard try await container.accountStatus() == .available else { throw CloudTransportError.accountChanged }
             let id = try await container.userRecordID()
             return .init(container: CloudSyncAvailability.containerIdentifier, environment: environment, userRecordName: id.recordName)
         },
         makeTransport: @escaping @MainActor (CloudSyncJournal) -> any CloudSyncTransport = { journal in
             CloudKitAccountSync(journal: journal, keys: CloudKeyStore(journal: journal),
                 assets: .init(root: journal.paths.partition(for: journal.owner).appendingPathComponent("outgoing")))
         }) {
        self.profiles = profiles; self.preferences = preferences; self.availability = availability
        self.identity = identity; self.makeTransport = makeTransport
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            guard let saved = try preferences.read(), saved.preferences.enabled else { status = .off; return }
            guard !saved.preferences.paused, saved.preferences.transferPause == nil else { status = .paused; return }
            await activate(explicit: false)
        } catch { status = .failed }
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            guard started, !profiles.isTransferring else { return }
            let requested = UUID()
            await stopEngine(requestedIntent: requested)
            guard intent == requested, started else { return }
            await activate(explicit: true)
        } else {
            // Invalidate before any await; old owner callbacks cannot apply/ack state.
            intent = UUID(); epoch = nil; isEnabled = false; status = .off
            do { try preferences.update { $0.enabled = false } } catch { status = .failed }
            await stopEngine()
        }
    }

    private func activate(explicit: Bool) async {
        let admission = UUID(); intent = admission
        guard let environment = availability() else { status = .unavailable; return }
        do {
            if explicit { try preferences.update { $0.enabled = true } }
            guard try preferences.read()?.preferences.enabled == true else { status = .off; return }
            let current = try await identity(environment)
            guard intent == admission, started else { return }
            guard current.environment == environment, current.container == CloudSyncAvailability.containerIdentifier else { throw CloudJournalError.ownerMismatch }
            let saved = try preferences.update {
                if explicit { $0.setConsent(enabled: true, for: current) }
                else { $0.observeOwner(current) }
            }
            restoringUnion = explicit && saved.preferences.paused
            guard saved.preferences.canResume(for: current) || restoringUnion else {
                status = saved.preferences.paused ? .paused : .needsConsent
                return
            }
            let journal = CloudSyncJournal(root: preferences.paths.root, owner: current)
            let newEpoch = UUID()
            let bridge = CloudCatalogBridge(profiles: profiles, journal: journal, deviceID: saved.deviceID, epoch: newEpoch)
            let startingState = try journal.catalogState()
            try profiles.initializeFreshCloudCatalog(state: startingState)
            let firstUnion = startingState.profiles.isEmpty || startingState.initialCatalogProjection != nil
            self.bridge = bridge
            bridge.attach()
            if restoringUnion {
                // Device restore pause remains durable while transport obtains the
                // initial union; publication stays closed until remap/application.
                try journal.catalogTransaction { state in
                    if state.restoreProfileRemap == nil { state.restoreIntent = nil }
                }
            }
            // Startup receipt recovery precedes local reconciliation/native startup.
            var recoveryDeferred = false
            do { try await bridge.recoverPending() }
            catch CloudJournalError.applicationPending { recoveryDeferred = true }
            guard intent == admission, started else { return }
            if firstUnion {
                _ = try profiles.cloudCatalogRead().projection()
                try bridge.pauseLocalAdmission()
            } else if !recoveryDeferred { try bridge.reconcileLocal(inferDeletions: !explicit && !restoringUnion) }
            try journal.catalogTransaction {
                if $0.transport == nil { $0.transport = .init() }
                $0.transport?.catalogPublicationPaused = true
                $0.transport?.includeSavedSessions = saved.preferences.includesSessions(for: current)
                $0.transport?.initialized = false
                $0.engineState = nil
            }
            owner = current; epoch = newEpoch; self.bridge = bridge; bridge.attach()
            includesSessions = saved.preferences.includesSessions(for: current)
            let engine = makeTransport(journal); transport = engine
            isEnabled = true; needsInitialUnion = true; status = .syncing
            bridge.onCommit = { [weak self] in
                guard let self else { return }
                self.status = .pending
                Task { [weak self] in await self?.syncNow() }
            }
            listener = Task { [weak self] in
                for await event in engine.events {
                    guard !Task.isCancelled else { return }
                    await self?.receive(event)
                }
            }
            try await engine.start(owner: current, epoch: newEpoch)
            guard intent == admission, epoch == newEpoch, isEnabled else { await engine.stop(); return }
            if let real = engine as? CloudKitAccountSync, try journal.catalogState().transport?.zoneEstablished != true {
                try await real.createZoneForFirstUse()
            }
            guard intent == admission else { return }
            await syncNow()
        } catch {
            guard intent == admission else { return }
            status = .failed
            await stopEngine()
        }
    }

    func setIncludesSessions(_ includes: Bool) async {
        guard let owner else { return }
        do {
            try preferences.update { $0.setIncludesSessions(includes, for: owner) }
            includesSessions = includes
            // Drain any previously admitted session batch before changing publication.
            let wasEnabled = isEnabled
            let requested = UUID()
            await stopEngine(requestedIntent: requested)
            guard intent == requested, started else { return }
            if wasEnabled { await activate(explicit: false) }
        } catch { status = .failed }
    }

    func syncNow() async {
        if let pass { await pass.value; return }
        guard isEnabled, let epoch, let owner, let engine = transport, let bridge else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await identity(owner.environment)
                guard self.epoch == epoch, isEnabled else { return }
                guard current == owner else { await accountChanged(current); return }
                try await bridge.recoverPending()
                guard self.epoch == epoch, isEnabled else { return }
                try bridge.reconcileLocal(inferDeletions: false)
                verifiedPass = false
                status = .syncing
                try await engine.syncNow()
                guard self.epoch == epoch, isEnabled else { return }
                guard try bridge.journal.catalogState().transport?.initialized == true else { throw CloudTransportError.fetchRequired }
                try bridge.completeInitialUnion()
                if restoringUnion { try bridge.restoreUnion() }
                try await bridge.applyRemote(profiles: [], order: nil, epoch: epoch)
                guard self.epoch == epoch, isEnabled else { return }
                if needsInitialUnion {
                    if restoringUnion {
                        try preferences.update { try $0.completeRestoreUnion(for: owner) }
                        restoringUnion = false
                    }
                    try bridge.journal.catalogTransaction { state in
                        guard state.transport?.initialized == true else { throw CloudTransportError.fetchRequired }
                        state.transport?.catalogPublicationPaused = false
                    }
                    needsInitialUnion = false
                    try await engine.syncNow()
                    guard self.epoch == epoch, isEnabled else { return }
                    try await bridge.applyRemote(profiles: [], order: nil, epoch: epoch)
                }
                verifiedPass = true
                try refreshStatus()
            } catch {
                guard self.epoch == epoch, isEnabled else { return }
                verifiedPass = false
                status = error as? CloudJournalError == .applicationPending ? .pending : .failed
            }
        }
        pass = task
        await task.value
        if self.epoch == epoch { pass = nil }
    }

    private func receive(_ event: CloudTransportEvent) async {
        guard isEnabled, event.epoch == epoch, event.owner == owner else { return }
        switch event.value {
        case .accountChanged: await accountChanged(nil)
        case .received:
            guard pass == nil, !needsInitialUnion, let bridge else { return }
            do {
                try await bridge.applyRemote(profiles: [], order: nil, epoch: event.epoch)
                guard isEnabled, event.epoch == epoch else { return }
                try refreshStatus()
            } catch { if event.epoch == epoch { status = .pending } }
        case .sent: break
        case .status(let value):
            if value == .upToDate {
                if pass == nil { do { try refreshStatus() } catch { status = .failed } }
            } else if case .paused = value { verifiedPass = false; status = .paused }
            else if value != .syncing { verifiedPass = false; status = .pending }
        }
    }

    private func refreshStatus() throws {
        guard let bridge, isEnabled else { return }
        let state = try bridge.journal.catalogState()
        let clean = verifiedPass && !needsInitialUnion && bridge.failure == nil && state.dirtyGenerations.isEmpty &&
            state.receipts.values.allSatisfy { $0.phase == .applied } && state.restoreIntent == nil &&
            state.transport?.blockedRecords.isEmpty != false && state.transport?.retryAfter.isEmpty != false &&
            state.transport?.pendingSessionDeletes.isEmpty != false
        status = clean ? .upToDate : .pending
    }

    private func accountChanged(_ current: CloudOwner?) async {
        intent = UUID(); epoch = nil; isEnabled = false; status = .needsConsent
        do { try preferences.update { prefs in
            if let current { prefs.observeOwner(current) } else { prefs.enabled = false }
        } } catch { status = .failed }
        await stopEngine()
    }

    func pauseForTransfer(restoring: Bool) async throws {
        // Off and never-used startup/backup does not create a sync identity.
        if try preferences.read() != nil { try preferences.update { try $0.beginTransfer(restoring: restoring) } }
        let previousBridge = bridge
        let saved = try preferences.read()
        pausedJournal = bridge?.journal ?? saved?.preferences.previousActiveOwner.map { CloudSyncJournal(root: preferences.paths.root, owner: $0) }
        status = .paused
        await stopEngine(holdCatalogForTransfer: true)
        if let journal = pausedJournal, let saved {
            let recovery = previousBridge ?? CloudCatalogBridge(profiles: profiles, journal: journal, deviceID: saved.deviceID, epoch: UUID())
            // Reattach only for synchronous write admission during recovery.
            let recoveryWriter = CloudCatalogBridge(profiles: profiles, journal: journal, deviceID: saved.deviceID, epoch: UUID())
            recoveryWriter.attach()
            defer {
                recoveryWriter.stop()
                profiles.cloudCatalogWriteAdmission = { throw CloudJournalError.applicationPending }
            }
            try await recoveryWriter.recoverPending()
            try recovery.reconcileLocal(inferDeletions: false)
        }
    }

    func markRestoreCommitAttempt(restoredProfiles: [PlusProfile]? = nil) throws {
        if try preferences.read()?.preferences.transferPause != nil { try preferences.update { try $0.markRestoreCommitAttempt() } }
        if let journal = pausedJournal, let restoredProfiles {
            let current = try profiles.cloudCatalogRead().projection()
            let target = CloudCatalogBridge.projection(restoredProfiles)
            try journal.catalogTransaction {
                guard !$0.receipts.values.contains(where: { $0.phase == .applying }), $0.restoreIntent == nil else {
                    throw CloudJournalError.applicationPending
                }
                $0.restoreIntent = .init(id: UUID(), expectedPreDigest: try current.digest(), expectedPostDigest: try target.digest(), postProjection: target)
            }
        }
    }

    func resumeAfterTransfer(restored: Bool) async {
        do {
            if let journal = pausedJournal {
                profiles.cloudCatalogWriteAdmission = {
                    let state = try journal.catalogState()
                    guard state.restoreIntent == nil, !state.receipts.values.contains(where: { $0.phase == .applying }) else {
                        throw CloudJournalError.applicationPending
                    }
                }
            } else { profiles.cloudCatalogWriteAdmission = nil }
            guard try preferences.read() != nil else { status = .off; return }
            let saved = try preferences.update { $0.finishTransfer(restored: restored) }
            if saved.preferences.paused { status = .paused }
            else if saved.preferences.enabled { await activate(explicit: false) }
            else { status = .off }
        } catch { status = .failed }
    }

    func notificationRegistrationFailed() { deliveryDegraded = true }
    func notificationRegistrationSucceeded() { deliveryDegraded = false }

    func sessionAdmission(for profileID: UUID) -> CloudSessionAdmission? {
        guard isEnabled, includesSessions, !needsInitialUnion, let owner, let epoch,
              (try? profiles.cloudCommittedRows().contains { $0.id == profileID }) == true else { return nil }
        return .init(owner: owner, epoch: epoch, profileID: profileID)
    }

    /// Capture/adoption services use this narrow final admission after their awaits.
    /// Neither a removed profile nor an old owner/session-inclusion epoch can queue.
    func commitCapturedSession(_ document: CloudSessionDocument, admission: CloudSessionAdmission) throws {
        guard isEnabled, includesSessions, !needsInitialUnion, admission.owner == owner, admission.epoch == epoch,
              document.profileID == admission.profileID, let bridge,
              try profiles.cloudCommittedRows().contains(where: { $0.id == document.profileID }) else { throw CloudTransportError.notStarted }
        try bridge.journal.catalogTransaction { state in
            guard state.restoreIntent == nil,
                  let profile = state.profiles[CloudJournalState.profileRecordName(document.profileID)],
                  profile.tombstone == nil else { throw CloudJournalError.invalidTransition }
            let name = CloudRecordCodec.recordName(for: .session(document))
            if let existing = state.sessions[name] {
                guard existing == document else { throw CloudSyncModelError.conflictingVersion }
                return
            }
            state.sessions[name] = document
            try state.markDirty(recordName: name, body: .session(document))
        }
        status = .pending
    }

    func stop() async { started = false; await stopEngine() }

    private func stopEngine(requestedIntent: UUID = UUID(), holdCatalogForTransfer: Bool = false) async {
        intent = requestedIntent; epoch = nil; isEnabled = false
        verifiedPass = false
        let previousBridge = bridge
        bridge?.stop(); bridge = nil
        if holdCatalogForTransfer { profiles.cloudCatalogWriteAdmission = { throw CloudJournalError.applicationPending } }
        listener?.cancel(); listener = nil
        let engine = transport; transport = nil
        let pending = pass; pass = nil; pending?.cancel()
        await engine?.stop()
        await previousBridge?.drainApplications()
        // Never await our own sync pass (account change is detected inside it).
    }
}
