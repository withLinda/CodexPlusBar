import CloudKit
import Foundation
import Observation

enum CloudSyncStatus: Equatable { case off, unavailable, needsConsent, syncing, upToDate, paused, pending, failed }

struct CloudSessionAdmission: Equatable, Sendable {
    let owner: CloudOwner
    let epoch: UUID
    let profileID: UUID
    let webDataStoreID: UUID
    let desktopIdentity: CodexSignInIdentity?
    let openChamberIdentity: OpenCodeOpenAIIdentity?
    let credentialRevision: UInt64
}

@Observable @MainActor final class CloudSyncCoordinator {
    private(set) var status: CloudSyncStatus = .off
    private(set) var isEnabled = false
    private(set) var includesSessions = true
    private(set) var deliveryDegraded = false
    private(set) var lastSuccessfulSync: Date?
    private(set) var issue: CloudSyncIssue?
    var isInitialMerge: Bool { needsInitialUnion }
    var isTransferring: Bool { profiles.isTransferring }
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
    @ObservationIgnored private var localServicesReady: (@MainActor () -> Void)?
    @ObservationIgnored private var intent = UUID()
    @ObservationIgnored private var needsInitialUnion = true
    @ObservationIgnored private var verifiedPass = false
    @ObservationIgnored private var restoringUnion = false
    @ObservationIgnored private var pausedJournal: CloudSyncJournal?
    @ObservationIgnored private let snapshots: CloudSessionSnapshotService
    @ObservationIgnored private let makeSessionInbox: @MainActor (CloudSyncJournal) -> CloudSessionInbox
    @ObservationIgnored private var sessionInbox: CloudSessionInbox?
    @ObservationIgnored private var sessionObserver: CloudSessionChangeObserver?
    @ObservationIgnored private var sessionChangeTask: Task<Void, Never>?
    @ObservationIgnored private var sessionChangeCounter: UInt64 = 0
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private let nativeAdoption: @MainActor (CloudSessionAdoptionAuthorization) -> CloudNativeSessionAdoption
    @ObservationIgnored private let sourceName: @MainActor () -> String

    init(profiles: PlusProfileController, preferences: CloudSyncPreferencesStore = .init(),
         availability: @escaping @MainActor () -> CloudEnvironment? = { CloudSyncAvailability().environment },
         identity: @escaping @MainActor (CloudEnvironment) async throws -> CloudOwner = { environment in
             let container = try CloudSyncAvailability().withContainer(environment: environment) { CKContainer(identifier: $0) }
             guard try await container.accountStatus() == .available else { throw CloudTransportError.accountChanged }
             let id = try await container.userRecordID()
             return .init(container: CloudSyncAvailability.containerIdentifier, environment: environment, userRecordName: id.recordName)
         },
         snapshots: CloudSessionSnapshotService? = nil,
         sourceName: @escaping @MainActor () -> String = { Host.current().localizedName ?? "Mac" },
         nativeAdoption: @escaping @MainActor (CloudSessionAdoptionAuthorization) -> CloudNativeSessionAdoption = { .init(authorization: $0) },
         makeSessionInbox: @escaping @MainActor (CloudSyncJournal) -> CloudSessionInbox = { journal in
             .init(journal: journal, keys: CloudKeyStore(journal: journal))
         },
         makeTransport: @escaping @MainActor (CloudSyncJournal) -> any CloudSyncTransport = { journal in
             CloudKitAccountSync(journal: journal, keys: CloudKeyStore(journal: journal),
                 assets: .init(root: journal.paths.partition(for: journal.owner).appendingPathComponent("outgoing")))
         }) {
        self.profiles = profiles; self.preferences = preferences; self.availability = availability
        self.identity = identity; self.makeTransport = makeTransport
        self.snapshots = snapshots ?? profiles.cloudSessionSnapshotService()
        self.makeSessionInbox = makeSessionInbox
        self.nativeAdoption = nativeAdoption
        self.sourceName = sourceName
        self.snapshots.adoption = { [weak self] request in
            guard let self else { throw CloudSessionError.unavailable }
            try await self.adoptSession(request)
        }
    }

    func start(localServicesReady: (@MainActor () -> Void)? = nil) async {
        guard !started else { return }
        started = true
        self.localServicesReady = localServicesReady
        profiles.isWaitingForCloudRecovery = true
        sessionObserver = CloudSessionChangeObserver { [weak self] in
            Task { @MainActor [weak self] in self?.requestSessionCapture() }
        }
        // Fail closed on an unreadable local recovery binding, even while off.
        profiles.cloudCatalogWriteAdmission = { throw CloudJournalError.applicationPending }
        do {
            let saved = try preferences.read()
            includesSessions = saved?.preferences.includeSavedSessions ?? true
            if let owner = saved?.preferences.previousActiveOwner {
                let journal = CloudSyncJournal(root: preferences.paths.root, owner: owner)
                lastSuccessfulSync = try journal.existingCatalogState()?.lastSuccess
                profiles.cloudCatalogWriteAdmission = {
                    guard let state = try journal.existingCatalogState() else { return }
                    guard state.restoreIntent == nil, !state.receipts.values.contains(where: { $0.phase == .applying }) else {
                        throw CloudJournalError.applicationPending
                    }
                }
            } else { profiles.cloudCatalogWriteAdmission = nil }
            // Local refresh and selector publication need a settled local catalog,
            // not an iCloud identity lookup or a completed network sync. Keep the
            // callback pending only when durable recovery still forbids writes.
            startLocalServicesIfReady()
            guard let saved, saved.preferences.enabled else { status = .off; return }
            guard !saved.preferences.paused, saved.preferences.transferPause == nil else { status = .paused; return }
            await activate(explicit: false)
        } catch { issue = CloudSyncIssue(error); status = .failed }
    }

    private func startLocalServicesIfReady() {
        guard started, !Task.isCancelled,
              localServicesReady != nil || profiles.isWaitingForCloudRecovery else { return }
        do { try profiles.cloudCatalogWriteAdmission?() }
        catch { return }
        profiles.isWaitingForCloudRecovery = false
        let ready = localServicesReady
        localServicesReady = nil
        ready?()
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
            intent = UUID(); epoch = nil; isEnabled = false; status = .off; issue = nil
            do { try preferences.update { $0.enabled = false } } catch { issue = CloudSyncIssue(error); status = .failed }
            await stopEngine()
        }
    }

    private func activate(explicit: Bool) async {
        issue = nil
        let admission = UUID(); intent = admission
        guard let environment = availability() else { status = .unavailable; return }
        do {
            if explicit { try preferences.update { $0.enabled = true } }
            guard try preferences.read()?.preferences.enabled == true else { status = .off; return }
            let current = try await identity(environment)
            guard intent == admission, started else { return }
            guard current.environment == environment, current.container == CloudSyncAvailability.containerIdentifier else { throw CloudJournalError.ownerMismatch }
            let journal = CloudSyncJournal(root: preferences.paths.root, owner: current)
            lastSuccessfulSync = try journal.existingCatalogState()?.lastSuccess
            let saved = try preferences.update {
                if explicit { $0.setConsent(enabled: true, for: current) }
                else { $0.observeOwner(current) }
            }
            restoringUnion = explicit && saved.preferences.paused
            guard saved.preferences.canResume(for: current) || restoringUnion else {
                status = saved.preferences.paused ? .paused : .needsConsent
                return
            }
            let newEpoch = UUID()
            let bridge = CloudCatalogBridge(profiles: profiles, journal: journal, deviceID: saved.deviceID, epoch: newEpoch)
            let startingState = try journal.catalogState()
            try profiles.initializeFreshCloudCatalog(state: startingState)
            let firstUnion = startingState.profiles.isEmpty || startingState.initialCatalogProjection != nil
            self.bridge = bridge
            // Local refresh is already running. Protect the initial baseline
            // before attaching callbacks or awaiting native-operation drain.
            if firstUnion { try bridge.pauseLocalAdmission() }
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
            startLocalServicesIfReady()
            if !firstUnion, !recoveryDeferred { try bridge.reconcileLocal(inferDeletions: !explicit && !restoringUnion) }
            try journal.catalogTransaction {
                $0.compactLocalSessions()
                if $0.transport == nil { $0.transport = .init() }
                $0.transport?.catalogPublicationPaused = true
                $0.transport?.includeSavedSessions = saved.preferences.includesSessions(for: current)
                $0.transport?.validatedSessionRecords = []
                $0.transport?.initialized = false
                $0.engineState = nil
            }
            owner = current; epoch = newEpoch; self.bridge = bridge; bridge.attach()
            includesSessions = saved.preferences.includesSessions(for: current)
            sessionInbox = makeSessionInbox(journal)
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
            issue = CloudSyncIssue(error)
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
        } catch { issue = CloudSyncIssue(error); status = .failed }
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
                startLocalServicesIfReady()
                try bridge.reconcileLocal(inferDeletions: false)
                await captureSavedSessions()
                guard self.epoch == epoch, isEnabled else { return }
                verifiedPass = false
                issue = nil
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
                    await captureSavedSessions()
                    guard self.epoch == epoch, isEnabled else { return }
                    try await engine.syncNow()
                    guard self.epoch == epoch, isEnabled else { return }
                    try await bridge.applyRemote(profiles: [], order: nil, epoch: epoch)
                }
                verifiedPass = true
                startLocalServicesIfReady()
                try refreshStatus()
            } catch {
                guard self.epoch == epoch, isEnabled else { return }
                verifiedPass = false
                issue = CloudSyncIssue(error)
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
            } catch { if event.epoch == epoch { issue = CloudSyncIssue(error); status = .pending } }
        case .sent: break
        case .status(let value):
            switch value {
            case .waitingForKey: issue = .keychain
            case .retrying: issue = .network
            case .quota: issue = .quota
            case .quarantined, .itemFailure: issue = .storage
            case .paused(let error): issue = CloudSyncIssue(error)
            case .upToDate: issue = nil
            case .syncing: break
            }
            if value == .upToDate {
                if pass == nil { do { try refreshStatus() } catch { issue = CloudSyncIssue(error); status = .failed } }
            } else if case .paused = value { verifiedPass = false; status = .paused }
            else if value != .syncing { verifiedPass = false; status = .pending }
        }
    }

    private func refreshStatus() throws {
        guard let bridge, isEnabled else { return }
        let state = try bridge.journal.catalogState()
        lastSuccessfulSync = state.lastSuccess ?? lastSuccessfulSync
        // Authenticated saved sessions are synced once durably received. Import is
        // a separate, explicit local action, so its retained receipt is not backlog.
        let receiptsSettled = state.receipts.allSatisfy { id, receipt in
            receipt.phase == .applied || (receipt.phase == .received &&
                state.receivedEnvelopes[id]?.recordName.hasPrefix("session.") == true &&
                state.transport?.processedInbox.contains(id) == true)
        }
        let clean = verifiedPass && !needsInitialUnion && bridge.failure == nil && state.dirtyGenerations.isEmpty &&
            receiptsSettled && state.restoreIntent == nil &&
            state.transport?.blockedRecords.isEmpty != false && state.transport?.retryAfter.isEmpty != false &&
            state.transport?.pendingSessionDeletes.isEmpty != false
        status = clean ? .upToDate : .pending
    }

    private func accountChanged(_ current: CloudOwner?) async {
        intent = UUID(); epoch = nil; isEnabled = false; status = .needsConsent
        lastSuccessfulSync = nil; issue = .account
        do { try preferences.update { prefs in
            if let current { prefs.observeOwner(current) } else { prefs.enabled = false }
        } } catch { issue = CloudSyncIssue(error); status = .failed }
        await stopEngine()
    }

    func pauseForTransfer(restoring: Bool) async throws {
        // Off and never-used startup/backup does not create a sync identity.
        if try preferences.read() != nil { try preferences.update { try $0.beginTransfer(restoring: restoring) } }
        let previousBridge = bridge
        let saved = try preferences.read()
        pausedJournal = bridge?.journal ?? saved?.preferences.previousActiveOwner.map { CloudSyncJournal(root: preferences.paths.root, owner: $0) }
        status = .paused; issue = nil
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
        } catch { issue = CloudSyncIssue(error); status = .failed }
    }

    func notificationRegistrationFailed() { deliveryDegraded = true }
    func notificationRegistrationSucceeded() { deliveryDegraded = false }

    func sessionAdmission(for profileID: UUID) -> CloudSessionAdmission? {
        guard isEnabled, includesSessions, !needsInitialUnion, let owner, let epoch,
              profiles.cloudSessionCaptureAllowed(for: profileID),
              let row = try? profiles.cloudCommittedRows().first(where: { $0.id == profileID }), row.provider == .codex else { return nil }
        return .init(owner: owner, epoch: epoch, profileID: profileID, webDataStoreID: row.webDataStoreID,
            desktopIdentity: row.codexSignIn, openChamberIdentity: row.openCodeOpenAIAccount,
            credentialRevision: snapshots.revision)
    }

    func canAdoptSession(for profileID: UUID) -> Bool {
        sessionAdmission(for: profileID) != nil && profiles.canBeginCloudSessionAdoption(for: profileID)
    }

    /// Capture/adoption services use this narrow final admission after their awaits.
    /// Neither a removed profile nor an old owner/session-inclusion epoch can queue.
    func commitCapturedSession(_ document: CloudSessionDocument, admission: CloudSessionAdmission) throws {
        guard isEnabled, includesSessions, !needsInitialUnion, admission.owner == owner, admission.epoch == epoch,
              document.profileID == admission.profileID, let bridge,
              document.sourceDeviceID == (try preferences.read()?.deviceID),
              admission.credentialRevision == snapshots.revision,
              profiles.cloudSessionCaptureAllowed(for: admission.profileID),
              let row = try profiles.cloudCommittedRows().first(where: { $0.id == document.profileID }), row.provider == .codex,
              row.webDataStoreID == admission.webDataStoreID, row.codexSignIn == admission.desktopIdentity,
              row.openCodeOpenAIAccount == admission.openChamberIdentity else { throw CloudTransportError.notStarted }
        let payload = try JSONDecoder().decode(CloudSessionPayload.self, from: document.payload).validated()
        guard payload.kind == document.kind, document.revision > 0 else { throw CloudSessionError.invalidPayload }
        try payload.identity.validateBindings(of: row)
        let digest = try payload.digest()
        guard try CloudJournalCoding.encode(CloudRecordBody.session(document)).count <= CloudPayloadCipher.maximumPlaintextBytes else {
            throw CloudPayloadError.tooLarge
        }
        try bridge.journal.catalogTransaction { state in
            guard state.restoreIntent == nil, !state.receipts.values.contains(where: { $0.phase == .applying }),
                  let profile = state.profiles[CloudJournalState.profileRecordName(document.profileID)],
                  profile.tombstone == nil else { throw CloudJournalError.invalidTransition }
            state.compactLocalSessions()
            let name = CloudRecordCodec.recordName(for: .session(document))
            let previous = state.sessions.values.filter { $0.profileID == document.profileID && $0.sourceDeviceID == document.sourceDeviceID && $0.kind == document.kind }
                .max { $0.revision < $1.revision }
            if let previous, let saved = try? JSONDecoder().decode(CloudSessionPayload.self, from: previous.payload), try saved.digest() == digest {
                state.transport?.validatedSessionRecords?.insert(CloudRecordCodec.recordName(for: .session(previous)))
                return
            }
            if state.adoptedSessionDigests?[Self.sessionOriginKey(document.profileID, document.kind)] == digest { return }
            if let existing = state.sessions[name] {
                guard existing == document else { throw CloudSyncModelError.conflictingVersion }
                return
            }
            guard document.revision > state.latestSessionRevision(profileID: document.profileID,
                sourceDeviceID: document.sourceDeviceID, kind: document.kind) else { throw CloudSyncModelError.conflictingVersion }
            state.sessions[name] = document
            try state.markDirty(recordName: name, body: .session(document))
            state.transport?.validatedSessionRecords?.insert(name)
            for (oldName, old) in state.sessions where oldName != name && old.profileID == document.profileID && old.kind == document.kind {
                if old.sourceDeviceID == document.sourceDeviceID && old.revision < document.revision {
                    state.dirtyGenerations.removeValue(forKey: oldName)
                    state.transport?.validatedSessionRecords?.remove(oldName)
                } else if let oldPayload = try? JSONDecoder().decode(CloudSessionPayload.self, from: old.payload),
                          (try? oldPayload.identity) == (try? payload.identity),
                          let fingerprint = try? oldPayload.generationFingerprint, payload.consumed.contains(fingerprint) {
                    state.dirtyGenerations.removeValue(forKey: oldName)
                }
            }
            state.compactLocalSessions()
        }
        status = .pending
    }

    private static func sessionOriginKey(_ id: UUID, _ kind: CloudSessionKind) -> String { "\(id.uuidString).\(kind.rawValue)" }

    private func requestSessionCapture() {
        guard isEnabled, includesSessions, let epoch else { return }
        sessionChangeCounter &+= 1
        guard sessionChangeTask == nil else { return }
        sessionChangeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == epoch { sessionChangeTask = nil } }
            repeat {
                let counter = sessionChangeCounter
                await Task.yield()
                guard self.epoch == epoch, !Task.isCancelled else { return }
                if let pass { await pass.value }
                guard self.epoch == epoch, !Task.isCancelled else { return }
                if await captureSavedSessions() { await syncNow() }
                if counter == sessionChangeCounter { return }
            } while self.epoch == epoch && !Task.isCancelled
        }
    }

    @discardableResult func captureSavedSessions() async -> Bool {
        guard isEnabled, includesSessions, !needsInitialUnion,
              !capturing, let rows = try? profiles.cloudCommittedRows() else { return false }
        capturing = true
        let captureEpoch = epoch
        defer {
            capturing = false
            if epoch != captureEpoch, isEnabled { requestSessionCapture() }
        }
        var published = false
        for row in rows {
            guard let admission = sessionAdmission(for: row.id) else { continue }
            do {
                for payload in try await snapshots.capture(for: row) {
                    guard let bridge, admission.epoch == epoch,
                          let device = try preferences.read()?.deviceID else { continue }
                    let state = try bridge.journal.catalogState()
                    let previous = state.latestSessionRevision(profileID: row.id, sourceDeviceID: device, kind: payload.kind)
                    let (revision, overflow) = previous.addingReportingOverflow(1)
                    guard !overflow else { throw CloudSyncModelError.counterOverflow }
                    let name = sourceName().trimmingCharacters(in: .whitespacesAndNewlines)
                    let document = CloudSessionDocument(profileID: row.id, sourceDeviceID: device,
                        sourceName: name.isEmpty ? "Mac" : String(name.unicodeScalars.prefix(240)),
                        kind: payload.kind, revision: revision, capturedAt: .now, payload: try payload.encoded())
                    try commitCapturedSession(document, admission: admission)
                    let after = try bridge.journal.catalogState()
                    let newlyApproved = (after.transport?.validatedSessionRecords ?? []).subtracting(state.transport?.validatedSessionRecords ?? [])
                    let changed = after.sessions.count > state.sessions.count || newlyApproved.contains { after.dirtyGenerations[$0] != nil }
                    published = published || changed
                }
            } catch { continue }
        }
        return published
    }

    func sessionSummaries(for profileID: UUID) async throws -> [CloudSessionSummary] {
        guard let admission = sessionAdmission(for: profileID), let sessionInbox,
              let profile = try profiles.cloudCommittedRows().first(where: { $0.id == profileID }) else { return [] }
        let summaries = try await sessionInbox.summaries(for: profile)
        guard sessionAdmission(for: profileID) == admission else { return [] }
        return summaries
    }

    func sessionCandidate(recordName: String, for profileID: UUID, recovering: Bool = false) async throws -> CloudSessionCandidate {
        guard let admission = sessionAdmission(for: profileID), let sessionInbox,
              let profile = try profiles.cloudCommittedRows().first(where: { $0.id == profileID }) else { throw CloudSessionError.unavailable }
        let candidate = try await sessionInbox.candidate(recordName: recordName, for: profile, recovering: recovering)
        guard sessionAdmission(for: profileID) == admission, let bridge,
              try candidate.validationStamp == bridge.journal.catalogState().sessionInboxStamp(for: profileID) else {
            throw CloudSessionError.unavailable
        }
        return candidate
    }

    /// An explicit request resolves an exact authenticated inbox revision. Its
    /// stamp is checked again inside every destination write, not used as a lease.
    func adoptSession(_ request: CloudSessionAdoptionRequest) async throws {
        guard let admission = sessionAdmission(for: request.profileID),
              let profile = try profiles.cloudCommittedRows().first(where: { $0.id == request.profileID }) else { throw CloudSessionError.unavailable }
        let candidate = try await sessionCandidate(recordName: request.recordName, for: request.profileID, recovering: true)
        guard candidate.summary.revision == request.sourceRevision, candidate.summary.profileID == request.profileID,
              sessionAdmission(for: request.profileID) == admission else { throw CloudSessionError.unavailable }
        try profiles.beginCloudSessionAdoption(for: request.profileID)
        defer { profiles.finishCloudSessionAdoption() }
        let authorization = CloudSessionAdoptionAuthorization(owner: admission.owner, request: request,
            validate: { [weak self] in
                guard let self else { throw CloudSessionError.unavailable }
                try self.validateAdoption(candidate, admission: admission)
            }, completed: { [weak self] identity, kind, remote in
                guard let self else { throw CloudSessionError.unavailable }
                try self.validateAdoption(candidate, admission: admission)
                if remote { try self.recordAdoptedDigest(candidate, admission: admission) }
                try self.profiles.completeCloudSessionAdoption(identity: identity, kind: kind, profileID: request.profileID)
            }, validateGeneration: { [weak self] payload in
                guard let self, let bridge = self.bridge else { throw CloudSessionError.unavailable }
                try payload.identity.validateBindings(of: profile)
                let consumed = try bridge.journal.catalogState().consumedSessionFingerprints(profileID: profile.id, payload: payload)
                if let fingerprint = try payload.generationFingerprint,
                   consumed.contains(fingerprint) || candidate.consumedFingerprints.contains(fingerprint) { throw CloudSessionError.unavailable }
            }, sourceConsumed: candidate.sourceConsumed, browserCompleted: { [weak self] incoming, remote in
                guard let self else { throw CloudSessionError.unavailable }
                try self.validateAdoption(candidate, admission: admission)
                if remote { try self.recordAdoptedDigest(candidate, admission: admission) }
                try self.profiles.completeCloudBrowserAdoption(incoming)
            }, browserCommitStatus: { [weak self] incoming in
                guard let self else { throw CloudSessionError.unavailable }
                return try self.profiles.cloudCommittedRows().contains {
                    $0.id == incoming.id && $0.webDataStoreID == incoming.webDataStoreID
                }
            })
        await profiles.prepareCloudCatalogApply()
        try authorization.validate()
        let adapter = nativeAdoption(authorization)
        switch candidate.payload.kind {
        case .desktop: _ = try await adapter.adoptDesktop(candidate.payload, for: profile)
        case .openChamber: _ = try await adapter.adoptOpenChamber(candidate.payload, for: profile)
        case .browser: try await profiles.adoptCloudBrowserSession(candidate.payload, for: profile, authorization: authorization)
        }
    }

    private func validateAdoption(_ candidate: CloudSessionCandidate, admission: CloudSessionAdmission) throws {
        guard isEnabled, includesSessions, !needsInitialUnion, owner == admission.owner, epoch == admission.epoch,
              profiles.cloudSessionAdoptionAllowed(for: admission.profileID), let bridge,
              let row = try profiles.cloudCommittedRows().first(where: { $0.id == admission.profileID }), row.provider == .codex,
              row.webDataStoreID == admission.webDataStoreID, row.codexSignIn == admission.desktopIdentity,
              row.openCodeOpenAIAccount == admission.openChamberIdentity,
              let settings = try preferences.read()?.preferences, settings.canResume(for: admission.owner),
              settings.transferPause == nil else { throw CloudSessionError.unavailable }
        let state = try bridge.journal.catalogState()
        guard state.restoreIntent == nil, !state.receipts.values.contains(where: { $0.phase == .applying }),
              candidate.validationStamp != nil, try candidate.validationStamp == state.sessionInboxStamp(for: admission.profileID) else {
            throw CloudSessionError.unavailable
        }
    }

    /// Task 7/8 call only after their durable adoption. This records provenance;
    /// it neither writes native credentials nor creates a local source revision.
    func recordAdoptedSession(_ candidate: CloudSessionCandidate, admission: CloudSessionAdmission) throws {
        guard admission.epoch == epoch, admission.owner == owner,
              candidate.summary.profileID == admission.profileID,
              sessionAdmission(for: admission.profileID) != nil, let bridge else { throw CloudSessionError.unavailable }
        _ = bridge
        try recordAdoptedDigest(candidate, admission: admission)
    }

    private func recordAdoptedDigest(_ candidate: CloudSessionCandidate, admission: CloudSessionAdmission) throws {
        guard let bridge else { throw CloudSessionError.unavailable }
        let digest = try candidate.payload.digest()
        try bridge.journal.catalogTransaction {
            guard $0.profiles[CloudJournalState.profileRecordName(admission.profileID)]?.tombstone == nil else { throw CloudSessionError.unavailable }
            if $0.adoptedSessionDigests == nil { $0.adoptedSessionDigests = [:] }
            $0.adoptedSessionDigests?[Self.sessionOriginKey(admission.profileID, candidate.payload.kind)] = digest
        }
    }

    func stop() async {
        started = false
        localServicesReady = nil
        sessionObserver = nil
        await stopEngine()
    }

    private func stopEngine(requestedIntent: UUID = UUID(), holdCatalogForTransfer: Bool = false) async {
        intent = requestedIntent; epoch = nil; isEnabled = false
        sessionChangeTask?.cancel(); sessionChangeTask = nil; sessionInbox = nil
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
