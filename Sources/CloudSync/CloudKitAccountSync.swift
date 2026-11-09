import CloudKit
import Foundation

actor CloudKitAccountSync: CloudSyncTransport {
    nonisolated let events: AsyncStream<CloudTransportEvent>
    private let continuation: AsyncStream<CloudTransportEvent>.Continuation
    private let journal: CloudSyncJournal
    private let keys: any CloudKeyStoring
    private let codec: CloudRecordCodec
    private let makeDriver: @Sendable () -> any CloudEngineDriving
    private let work = CloudTransportSerial()
    private let lifecycle = CloudTransportSerial()
    private var driver: (any CloudEngineDriving)?
    private var owner: CloudOwner?
    private var epoch: UUID?
    /// A new internal token for each engine, including a change-token-expiration restart.
    private var token: UUID?
    private var desiredRun: UUID?
    private(set) var lifecycleIntent = UUID()
    private var drain: Task<Void, Never>?
    private var inFlight: [String: Flight] = [:]
    private var deleting: Set<String> = []
    private var waitingRecords: Set<String> = []
    private var attempted: Set<String> = []
    private var ready = false
    private var explicitFetches: Set<UUID> = []
    private var fetchIsActive = false
    private var fetchedZoneSuccessfully = false
    private var verifiedFetch = false
    private var retryTask: Task<Void, Never>?
    private(set) var recoveryTask: Task<Void, Never>?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private struct Flight {
        let encoded: CloudEncodedRecord
        let revision: CloudSentRevision
        let body: CloudRecordBody
    }

    /// Construction is inert. Production callers must pass their entitlement/account gate
    /// before start; tests inject both keys and driver and never construct CKContainer.
    init(journal: CloudSyncJournal, keys: any CloudKeyStoring, assets: CloudAssetStore,
         makeDriver: @escaping @Sendable () -> any CloudEngineDriving = { CloudKitEngineDriver() },
         now: @escaping @Sendable () -> Date = { .now },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds))
         }) {
        self.journal = journal; self.keys = keys; codec = CloudRecordCodec(assets: assets); self.makeDriver = makeDriver
        self.now = now; self.sleep = sleep
        // The durable inbox is the replay source. A slow/absent UI consumer must not
        // retain an unbounded number of 16 MiB ciphertext events in memory.
        let stream = AsyncStream<CloudTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = stream.stream; continuation = stream.continuation
    }

    deinit { retryTask?.cancel(); recoveryTask?.cancel(); continuation.finish() }

    func start(owner: CloudOwner, epoch: UUID) async throws {
        let intent = UUID()
        lifecycleIntent = intent
        try await lifecycle.run { try await self.startIsolated(owner: owner, epoch: epoch, intent: intent) }
    }

    private func startIsolated(owner: CloudOwner, epoch: UUID, intent: UUID) async throws {
        try checkIntent(intent)
        recoveryTask?.cancel(); recoveryTask = nil
        desiredRun = nil
        await beginDrain().value
        try checkIntent(intent)
        drain = nil
        guard owner == journal.owner else { throw CloudJournalError.ownerMismatch }
        self.owner = owner; self.epoch = epoch; desiredRun = UUID()
        try await openEngine(intent: intent)
    }

    private func openEngine(intent: UUID) async throws {
        let state = try await journal.load()
        try checkIntent(intent)
        guard state.transport?.zoneLost != true else { throw CloudTransportError.zoneLost }
        let newToken = UUID()
        ready = false
        explicitFetches.removeAll()
        fetchIsActive = false
        fetchedZoneSuccessfully = false
        verifiedFetch = false
        token = newToken
        let engine = makeDriver()
        driver = engine
        let callbacks = CloudEngineCallbacks(event: { [weak self] event in
            guard let self else { return }
            _ = try? await self.work.run { await self.process(event, token: newToken) }
        }, nextBatch: { [weak self] scope, pending in
            guard let self else { return nil }
            return try? await self.work.run { await self.batch(scope: scope, pending: pending, token: newToken) }
        })
        do {
            try await engine.start(owner: state.owner, state: state.engineState, callbacks: callbacks)
            try checkIntent(intent)
            try await work.run { try await self.replayInbox(token: newToken) }
            try checkIntent(intent)
            guard token == newToken else { throw CloudTransportError.notStarted }
            ready = true
            try await updatePending(token: newToken)
            try checkIntent(intent)
            if state.transport?.zoneCreationRequested == true { await engine.createZone() }
            try checkIntent(intent)
            emit(.status(.syncing))
        } catch {
            _ = beginDrain()
            throw error
        }
    }

    func stop() async {
        lifecycleIntent = UUID()
        // Close admission immediately, even if start is currently awaiting key delivery.
        desiredRun = nil; token = nil; ready = false
        recoveryTask?.cancel(); recoveryTask = nil
        _ = try? await lifecycle.run {
            await self.stopIsolated()
        }
    }

    private func stopIsolated() async {
        desiredRun = nil
        await beginDrain().value
        drain = nil
    }

    /// Never await cancellation inside a delegate callback: cancel waits for that callback.
    /// Invalidate immediately, then retain the entire flight table until cancellation drains.
    private func beginDrain() -> Task<Void, Never> {
        token = nil; ready = false; retryTask?.cancel(); retryTask = nil
        if let drain { return drain }
        let engine = driver
        let task = Task {
            await engine?.cancelOperations()
            _ = try? await work.run { await self.releaseAllFlights() }
        }
        drain = task
        return task
    }

    func syncNow() async throws {
        try await withTaskCancellationHandler {
            try await syncNowIsolated()
        } onCancel: { Task { await self.stop() } }
    }

    private func syncNowIsolated() async throws {
        guard let token, let driver else { throw CloudTransportError.notStarted }
        do {
            try await work.run {
                try await self.retryUserResolvableItems(token: token)
                try await self.replayInbox(token: token)
                try await self.updatePending(token: token)
            }
            try await fetchChanges(using: driver, token: token)
            try check(token)
            try await driver.sendChanges()
            try check(token)
        } catch {
            if let error = error as? CKError {
                await processNetworkError(error, recordName: "", token: token)
            } else if self.token == token {
                if error is CancellationError { _ = beginDrain() }
                else { storageFailed() }
            }
            throw error
        }
    }

    /// Only first-use creation is supported here. Unexpected loss requires a separate,
    /// explicit recovery decision; it never flows back through this creation method.
    func createZoneForFirstUse() async throws {
        guard let token, let driver else { throw CloudTransportError.notStarted }
        try await journal.transaction { state in
            var transport = state.transport ?? .init()
            guard !transport.zoneLost, !transport.zoneEstablished else { throw CloudTransportError.zoneLost }
            transport.zoneCreationRequested = true; state.transport = transport
        }
        try check(token)
        await driver.createZone()
    }

    private func check(_ expected: UUID) throws {
        guard token == expected else { throw CloudTransportError.notStarted }
    }

    private func checkIntent(_ expected: UUID) throws {
        guard lifecycleIntent == expected else { throw CloudTransportError.notStarted }
    }

    private func emit(_ value: CloudTransportEvent.Value) {
        if let owner, let epoch { continuation.yield(.init(owner: owner, epoch: epoch, value: value)) }
    }

    private func process(_ event: CloudEngineEvent, token expected: UUID) async {
        guard token == expected else { return }
        do {
            switch event {
            case .engineStateFailure:
                throw CloudTransportError.storageFailure
            case .state(let bytes):
                try await journal.transaction { $0.engineState = bytes }
            case .fetched(let records, let deletions):
                for record in records where record.recordID.zoneID == CloudRecordCodec.zoneID {
                    try check(expected)
                    try await receive(record, token: expected)
                }
                for id in deletions where id.zoneID == CloudRecordCodec.zoneID {
                    try await journal.transaction { state in
                        if !Self.confirmSessionAbsence(id.recordName, in: &state) {
                            if state.transport == nil { state.transport = .init() }
                            state.transport?.blockedRecords[id.recordName] = .deleted
                        }
                    }
                    deleting.remove(id.recordName)
                    attempted.remove(id.recordName)
                }
                try await replayInbox(token: expected)
                try await updatePending(token: expected)
            case .zoneFetched(let error):
                if let error {
                    fetchedZoneSuccessfully = false
                    verifiedFetch = false
                    await processNetworkError(error, recordName: "", token: expected)
                }
                else {
                    fetchedZoneSuccessfully = true
                    try await journal.transaction { state in
                        var transport = state.transport ?? .init()
                        transport.initialized = true; transport.zoneEstablished = true
                        transport.retryAfter.removeValue(forKey: "")
                        state.transport = transport
                    }
                    try await updatePending(token: expected)
                }
            case .zoneSaved(let error):
                if let error { await processNetworkError(error, recordName: "", token: expected) }
                else {
                    try await journal.transaction { state in
                        var transport = state.transport ?? .init()
                        transport.zoneEstablished = true; transport.zoneCreationRequested = false
                        state.transport = transport
                    }
                }
            case .zoneLost:
                try await loseZone()
            case .accountChanged:
                emit(.accountChanged); emit(.status(.paused(.accountChanged)))
                lifecycleIntent = UUID()
                desiredRun = nil; _ = beginDrain()
            case .fetchStarted:
                fetchIsActive = true
                fetchedZoneSuccessfully = false
                verifiedFetch = false
                emit(.status(.syncing))
            case .fetchFinished:
                fetchIsActive = false
                // DidFetchChanges carries no success/error result. An automatic pass
                // needs affirmative zone success in this pass. Explicit requests wait
                // for fetchChanges() to return, after all delegate callbacks, or throw.
                verifiedFetch = fetchedZoneSuccessfully && explicitFetches.isEmpty
                fetchedZoneSuccessfully = false
                try await reportSuccessIfSettled(token: expected)
            case .sendFinished:
                // SDK completion is the other valid lease release boundary (including a
                // request that ended without per-item outcomes). Dirty work remains queued.
                releaseAllFlights()
                try await updatePending(token: expected)
                try await reportSuccessIfSettled(token: expected)
            case .sent(let saved, let failed, let deleted, let failedDeletes):
                for record in saved { try await acknowledge(record, token: expected) }
                for failure in failed {
                    let name = failure.record.recordID.recordName
                    guard inFlight[name] != nil else { continue }
                    if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord,
                       server.recordID == failure.record.recordID {
                        try await receive(server, token: expected)
                        try await replayInbox(token: expected)
                        attempted.remove(name)
                    } else { await processNetworkError(failure.error, recordName: name, token: expected) }
                    release(name)
                    try check(expected)
                }
                for id in deleted where deleting.contains(id.recordName) {
                    _ = try await journal.transaction { Self.confirmSessionAbsence(id.recordName, in: &$0) }
                    deleting.remove(id.recordName)
                }
                for (id, error) in failedDeletes where deleting.contains(id.recordName) {
                    if error.code == .unknownItem {
                        _ = try await journal.transaction { Self.confirmSessionAbsence(id.recordName, in: &$0) }
                    } else { await processNetworkError(error, recordName: id.recordName, token: expected) }
                    deleting.remove(id.recordName)
                }
                try await updatePending(token: expected)
            }
        } catch {
            guard token == expected else { return }
            storageFailed()
        }
    }

    private func receive(_ record: CKRecord, token expected: UUID) async throws {
        let envelope: CloudRecordEnvelope
        do { envelope = try codec.envelope(from: record) }
        catch {
            // A vanished/unreadable downloaded file is a local durability failure, not
            // malformed server content. Keep the previous cursor so it can be fetched again.
            guard error is CloudRecordCodecError || (error as? CloudJournalError) == .tooLarge else { throw error }
            // Invalid/oversized server data is item-specific. Retain a durable write block
            // before allowing the cursor past it; do not allocate an unbounded payload.
            let name = record.recordID.recordName
            try await journal.transaction { state in
                if state.transport == nil { state.transport = .init() }
                state.transport?.blockedRecords[name] = .invalid
            }
            emit(.status(.itemFailure(name)))
            return
        }
        try check(expected)
        // An applied receipt may have had its ciphertext cleaned. A duplicate fetch must
        // not recreate that receipt or infer another local edit.
        let state = try await journal.load()
        if state.receipts[envelope.id]?.phase == .applied { return }
        try await journal.receive(id: envelope.id, recordName: envelope.recordName,
            metadata: CloudJournalCoding.encode(envelope.routing), systemFields: envelope.systemFields,
            ciphertext: envelope.ciphertext, transportManaged: true)
    }

    private func replayInbox(token expected: UUID) async throws {
        let state = try await journal.load()
        var waiting: Set<String> = []
        for id in state.transport?.inboxOrder ?? [] {
            try check(expected)
            guard let stored = state.receivedEnvelopes[id], state.receipts[id]?.phase != .applied else { continue }
            let routing = try JSONDecoder().decode(CloudRecordRouting.self, from: stored.metadata)
            let envelope = CloudRecordEnvelope(id: id, recordName: stored.recordName, routing: routing,
                ciphertext: try await journal.ciphertext(for: id), systemFields: stored.systemFields)
            if state.receipts.values.contains(where: { $0.phase == .applying }) || state.restoreIntent != nil {
                waiting.insert(stored.recordName); continue
            }
            if state.transport?.processedInbox.contains(id) == true {
                if routing.kind != "session" || state.transport?.sessionReceipts[stored.recordName] == id {
                    emit(.received([envelope]))
                }
                continue
            }
            guard routing.schemaVersion == 1 else {
                waiting.insert(stored.recordName); emit(.status(.quarantined(stored.recordName))); continue
            }
            let key: CloudEncryptionKey?
            do { key = try await keys.key(id: routing.keyID, owner: state.owner) }
            catch { waiting.insert(stored.recordName); emit(.status(.waitingForKey(stored.recordName))); continue }
            try check(expected)
            guard let key else { waiting.insert(stored.recordName); emit(.status(.waitingForKey(stored.recordName))); continue }
            // Keep arrival order for each record. A missing older tombstone cannot be
            // bypassed by a decryptable newer update to that same UUID.
            guard !waiting.contains(stored.recordName) else { continue }
            let body: CloudRecordBody
            do { body = try codec.decode(envelope, owner: state.owner, key: key) }
            catch { waiting.insert(stored.recordName); emit(.status(.quarantined(stored.recordName))); continue }
            do {
                let publish = try await journal.transaction { state in try Self.mergeReceived(body, envelope: envelope, into: &state) }
                try check(expected)
                if publish { emit(.received([envelope])) }
            } catch let error as CloudSyncModelError {
                if error == .conflictingVersion {
                    waiting.insert(stored.recordName); emit(.status(.quarantined(stored.recordName))); continue
                }
                throw error
            } catch CloudJournalError.applicationPending {
                waiting.insert(stored.recordName); continue
            }
            try check(expected)
        }
        waitingRecords = waiting
        if !waiting.isEmpty { scheduleRetry(after: 30, token: expected) }
    }

    private static func mergeReceived(_ remote: CloudRecordBody, envelope: CloudRecordEnvelope, into state: inout CloudJournalState) throws -> Bool {
        guard !state.receipts.values.contains(where: { $0.phase == .applying }), state.restoreIntent == nil else {
            throw CloudJournalError.applicationPending
        }
        let name = envelope.recordName
        var transport = state.transport ?? .init()
        let local = state.body(for: name)
        let merged: CloudRecordBody
        var publish = true
        switch (local, remote) {
        case (.profile(let lhs)?, .profile(let rhs)): merged = .profile(try CloudProfileMerge.merge(lhs, rhs))
        case (.order(let lhs)?, .order(let rhs)):
            if lhs.version == rhs.version, lhs != rhs { throw CloudSyncModelError.conflictingVersion }
            merged = .order(lhs.version > rhs.version ? lhs : rhs)
        case (.session(let lhs)?, .session(let rhs)):
            guard lhs == rhs else { throw CloudSyncModelError.conflictingVersion }
            merged = remote
        case (nil, _): merged = remote
        default: throw CloudRecordCodecError.routingMismatch
        }
        switch merged {
        case .profile(let document):
            state.profiles[name] = document
            let versions = document.fields.versions + document.unknownFields.values.map(\.version)
            for version in versions { state.lamportCounter = max(state.lamportCounter, version.counter) }
            state.lamportCounter = max(state.lamportCounter, document.tombstone?.version.counter ?? 0)
            if case .profile(let received) = remote, received.tombstone != nil { transport.acknowledgedTombstones.insert(document.id) }
        case .order(let document):
            state.order = document; state.lamportCounter = max(state.lamportCounter, document.version.counter)
        case .session(let document):
            // Remote sessions stay encrypted in the inbox; only locally queued sessions
            // belong in state.sessions. No credentials are installed by transport.
            transport.sessionProfiles[name] = document.profileID
            transport.deletedSessions.remove(name)
            let digest = CloudJournalCoding.digest(try CloudJournalCoding.encode(document))
            if let previous = transport.sessionDigests[name], previous != digest { throw CloudSyncModelError.conflictingVersion }
            transport.sessionDigests[name] = digest
            if transport.sessionReceipts[name] != nil { publish = false }
            else { transport.sessionReceipts[name] = envelope.id }
        }
        if state.dirtyGenerations[name] != nil, local != merged { try state.markDirty(recordName: name, body: merged) }
        transport.processedInbox.insert(envelope.id)
        transport.blockedRecords.removeValue(forKey: name)
        state.systemFields[name] = envelope.systemFields
        for (sessionName, session) in state.sessions where transport.acknowledgedTombstones.contains(session.profileID) {
            transport.sessionProfiles[sessionName] = session.profileID
        }
        for (sessionName, profileID) in transport.sessionProfiles where transport.acknowledgedTombstones.contains(profileID) && !transport.deletedSessions.contains(sessionName) {
            transport.pendingSessionDeletes.insert(sessionName)
        }
        state.transport = transport
        return publish
    }

    private func updatePending(token expected: UUID) async throws {
        try check(expected)
        let state = try await journal.load()
        try check(expected)
        let deleting = state.transport?.pendingSessionDeletes ?? []
        let saves = state.dirtyGenerations.keys.filter { !deleting.contains($0) }.sorted()
            .map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudRecordCodec.recordID($0)) }
        let deletes = deleting.sorted().map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(CloudRecordCodec.recordID($0)) }
        await driver?.setPending(saves + deletes)
    }

    /// A fetched deletion, successful delete and unknown-item response are the same
    /// authoritative absence. Preserve local snapshots and generation high-water marks.
    private static func confirmSessionAbsence(_ name: String, in state: inout CloudJournalState) -> Bool {
        guard let profileID = state.transport?.sessionProfiles[name] ?? state.sessions[name]?.profileID else { return false }
        if state.transport == nil { state.transport = .init() }
        state.transport?.sessionProfiles[name] = profileID
        state.transport?.pendingSessionDeletes.remove(name)
        state.transport?.deletedSessions.insert(name)
        state.transport?.retryAfter.removeValue(forKey: name)
        state.transport?.blockedRecords.removeValue(forKey: name)
        state.dirtyGenerations.removeValue(forKey: name)
        return true
    }

    private func batch(scope: CKSyncEngine.SendChangesOptions.Scope, pending: [CKSyncEngine.PendingRecordZoneChange], token expected: UUID) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard token == expected, ready else { return nil }
        do {
            let state = try await journal.load()
            guard state.transport?.initialized == true, state.transport?.zoneLost != true,
                  state.transport?.catalogPublicationPaused != true,
                  !state.receipts.values.contains(where: { $0.phase == .applying }), state.restoreIntent == nil else { return nil }
            let now = now()
            guard state.transport?.blockedRecords[""] == nil,
                  (state.transport?.retryAfter[""] ?? .distantPast) <= now else { return nil }
            let changes = pending.filter { change in
                guard scope.contains(change) else { return false }
                let id: CKRecord.ID
                switch change {
                case .saveRecord(let value), .deleteRecord(let value): id = value
                @unknown default: return false
                }
                let name = id.recordName
                guard id.zoneID == CloudRecordCodec.zoneID, !waitingRecords.contains(name),
                       state.transport?.blockedRecords[name] == nil,
                       !(name.hasPrefix("session.") && state.transport?.includeSavedSessions == false),
                      (state.transport?.retryAfter[name] ?? .distantPast) <= now,
                      !attempted.contains(name), inFlight[name] == nil, !deleting.contains(name) else { return false }
                switch change {
                case .saveRecord:
                    guard state.dirtyGenerations[name] != nil else { return false }
                    if case .session(let session)? = state.body(for: name) {
                        return state.profiles[CloudJournalState.profileRecordName(session.profileID)]?.tombstone == nil
                    }
                    return true
                case .deleteRecord: return state.transport?.pendingSessionDeletes.contains(name) == true
                @unknown default: return false
                }
            }
            guard !changes.isEmpty else { return nil }
            let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] id in
                await self?.prepare(id.recordName, token: expected)
            }
            guard token == expected else { return nil }
            if let batch {
                for id in batch.recordIDsToDelete { deleting.insert(id.recordName); attempted.insert(id.recordName) }
                if batch.recordsToSave.isEmpty, batch.recordIDsToDelete.isEmpty { return nil }
            }
            return batch
        } catch {
            storageFailed(); return nil
        }
    }

    private func prepare(_ name: String, token expected: UUID) async -> CKRecord? {
        do {
            let state = try await journal.load()
            guard let revision = state.sentRevision(for: name), let body = state.body(for: name) else { return nil }
            let device = try await journal.deviceState().deviceID
            let key = try await keys.writerKey(owner: state.owner, deviceID: device)
            try check(expected)
            // Snapshot was captured before the key await. Its revision and body travel
            // together even when the coordinator commits a newer local edit meanwhile.
            let encoded = try codec.encode(body, owner: state.owner, key: key, systemFields: state.systemFields[name])
            inFlight[name] = Flight(encoded: encoded, revision: revision, body: body)
            attempted.insert(name)
            return encoded.record
        } catch is CloudKeyStoreError {
            emit(.status(.waitingForKey(name))); scheduleRetry(after: 30, token: expected); return nil
        } catch is CloudPayloadError {
            emit(.status(.itemFailure(name))); attempted.insert(name); return nil
        } catch {
            guard token == expected else { return nil }
            storageFailed(); return nil
        }
    }

    private func acknowledge(_ record: CKRecord, token expected: UUID) async throws {
        let name = record.recordID.recordName
        guard record.recordID.zoneID == CloudRecordCodec.zoneID, let flight = inFlight[name] else { return }
        let fields = try CloudRecordCodec.systemFields(of: record)
        try check(expected)
        try await journal.transaction { state in
            state.acknowledge(flight.revision)
            // Even an older generation's success supplies the server change tag needed
            // by the newer pending edit. It must not clear that newer generation.
            state.systemFields[name] = fields
            if state.transport == nil { state.transport = .init() }
            if case .profile(let profile) = flight.body, profile.tombstone != nil {
                state.transport?.acknowledgedTombstones.insert(profile.id)
                for (sessionName, session) in state.sessions where session.profileID == profile.id {
                    state.transport?.sessionProfiles[sessionName] = profile.id
                }
                for (sessionName, profileID) in state.transport?.sessionProfiles ?? [:]
                    where profileID == profile.id && state.transport?.deletedSessions.contains(sessionName) != true {
                    state.transport?.pendingSessionDeletes.insert(sessionName)
                }
            }
            if case .session(let session) = flight.body {
                state.transport?.sessionProfiles[name] = session.profileID
                if state.transport?.acknowledgedTombstones.contains(session.profileID) == true {
                    state.transport?.pendingSessionDeletes.insert(name)
                }
            }
            state.transport?.retryAfter.removeValue(forKey: name)
        }
        emit(.sent([flight.revision])); release(name); attempted.remove(name)
    }

    private func release(_ name: String) {
        guard let flight = inFlight.removeValue(forKey: name) else { return }
        flight.encoded.lease.release()
        // Failed cleanup retains ciphertext; never replace a successful journal commit
        // with speculative rollback or expose raw filesystem/CloudKit descriptions.
        try? codec.assets.remove(flight.encoded.assetURL)
    }

    private func releaseAllFlights() {
        for name in Array(inFlight.keys) { release(name) }
        deleting.removeAll(); attempted.removeAll()
    }

    private func loseZone() async throws {
        try await journal.transaction { state in
            if state.transport == nil { state.transport = .init() }
            state.transport?.zoneLost = true; state.transport?.initialized = false
        }
        lifecycleIntent = UUID()
        emit(.status(.paused(.zoneLost))); _ = beginDrain()
    }

    private func processNetworkError(_ error: CKError, recordName name: String, token expected: UUID) async {
        guard token == expected else { return }
        do {
            switch error.code {
            case .zoneNotFound:
                if try await journal.load().transport?.zoneEstablished == true { try await loseZone() }
                else { emit(.status(.paused(.fetchRequired))) }
            case .userDeletedZone: try await loseZone()
            case .changeTokenExpired:
                try await journal.transaction { state in
                    state.engineState = nil
                    if state.transport == nil { state.transport = .init() }
                    state.transport?.initialized = false
                }
                let wanted = desiredRun
                let draining = beginDrain()
                Task {
                    await draining.value
                    _ = try? await lifecycle.run { try await self.restartIfDesired(wanted) }
                }
            case .networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable,
                 .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
                let supplied = error.retryAfterSeconds ?? 30
                let delay = supplied.isFinite ? max(1, supplied) : 30
                let deadline = now().addingTimeInterval(delay)
                try await journal.transaction { state in
                    if state.transport == nil { state.transport = .init() }
                    state.transport?.retryAfter[name] = deadline
                }
                emit(.status(.retrying(name)))
                scheduleRetry(after: delay, token: expected)
            default:
                let block: CloudRecordBlock = error.code == .quotaExceeded ? .quota : .permanent
                try await journal.transaction { state in
                    if state.transport == nil { state.transport = .init() }
                    state.transport?.blockedRecords[name] = block
                }
                emit(.status(block == .quota ? .quota(name) : .itemFailure(name)))
            }
        } catch {
            storageFailed()
        }
    }

    private func retryUserResolvableItems(token expected: UUID) async throws {
        try check(expected)
        try await journal.transaction { state in
            guard var transport = state.transport else { return }
            transport.blockedRecords = transport.blockedRecords.filter { $0.value != .quota && $0.value != .permanent }
            state.transport = transport
        }
    }

    private func scheduleRetry(after delay: TimeInterval, token expected: UUID) {
        guard token == expected, retryTask == nil else { return }
        let sleep = sleep
        retryTask = Task { [weak self] in
            do { try await sleep(min(delay, 300)); try Task.checkCancellation() }
            catch { return }
            await self?.retryWake(token: expected)
        }
    }

    private func retryWake(token expected: UUID) async {
        retryTask = nil
        guard token == expected, let driver else { return }
        do {
            try await work.run {
                try await self.replayInbox(token: expected)
                try await self.updatePending(token: expected)
            }
            try check(expected)
            let beforeRequest = try await journal.load()
            if let deadline = beforeRequest.transport?.retryAfter.values.filter({ $0 > now() }).min() {
                // Key delivery and persisted replay may be retried locally while a server
                // throttle is active. A bounded timer wake is not permission to network.
                scheduleRetry(after: deadline.timeIntervalSince(now()), token: expected)
                return
            }
            try await fetchChanges(using: driver, token: expected)
            try check(expected)
            try await driver.sendChanges()
            let state = try await journal.load()
            if let deadline = state.transport?.retryAfter.values.min() {
                scheduleRetry(after: max(30, deadline.timeIntervalSince(now())), token: expected)
            }
        } catch {
            if let ckError = error as? CKError { await processNetworkError(ckError, recordName: "", token: expected) }
            else if token == expected { storageFailed() }
        }
    }

    private func storageFailed() {
        emit(.status(.paused(.storageFailure)))
        let wanted = desiredRun
        let draining = beginDrain()
        guard wanted != nil, recoveryTask == nil else { return }
        let sleep = sleep
        recoveryTask = Task { [weak self] in
            await draining.value
            do { try await sleep(30); try Task.checkCancellation() }
            catch { return }
            await self?.recoverStorage(wanted)
        }
    }

    private func recoverStorage(_ wanted: UUID?) async {
        guard desiredRun == wanted, wanted != nil else { return }
        recoveryTask = nil
        do { try await lifecycle.run { try await self.restartIfDesired(wanted) } }
        catch { if desiredRun == wanted { storageFailed() } }
    }

    private func restartIfDesired(_ wanted: UUID?) async throws {
        guard wanted != nil, desiredRun == wanted else { return }
        let intent = lifecycleIntent
        drain = nil
        try await openEngine(intent: intent)
        try checkIntent(intent)
        if let driver, let token { try await fetchChanges(using: driver, token: token) }
    }

    private func fetchChanges(using driver: any CloudEngineDriving, token expected: UUID) async throws {
        let request = UUID()
        try await work.run { try await self.beginExplicitFetch(request, token: expected) }
        do {
            try await driver.fetchChanges()
            try await work.run { try await self.finishExplicitFetch(request, succeeded: true, token: expected) }
        } catch {
            _ = try? await work.run { try await self.finishExplicitFetch(request, succeeded: false, token: expected) }
            throw error
        }
    }

    private func beginExplicitFetch(_ request: UUID, token expected: UUID) throws {
        try check(expected)
        explicitFetches.insert(request)
        verifiedFetch = false
    }

    private func finishExplicitFetch(_ request: UUID, succeeded: Bool, token expected: UUID) async throws {
        try check(expected)
        explicitFetches.remove(request)
        verifiedFetch = succeeded && explicitFetches.isEmpty && !fetchIsActive
        if verifiedFetch {
            _ = try await journal.transaction { $0.transport?.retryAfter.removeValue(forKey: "") }
            try await reportSuccessIfSettled(token: expected)
        }
    }

    private func reportSuccessIfSettled(token expected: UUID) async throws {
        try check(expected)
        guard verifiedFetch, !fetchIsActive, explicitFetches.isEmpty,
              inFlight.isEmpty, deleting.isEmpty, waitingRecords.isEmpty else { return }
        let updated = try await journal.transaction { state -> Bool in
            guard let transport = state.transport, transport.initialized, !transport.zoneLost,
                  transport.blockedRecords.isEmpty, transport.pendingSessionDeletes.isEmpty,
                  transport.retryAfter.isEmpty, state.dirtyGenerations.isEmpty else { return false }
            state.lastSuccess = .now; return true
        }
        if updated { emit(.status(.upToDate)) }
    }
}
