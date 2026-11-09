import Foundation

/// All admissions run on MainActor. Intent/catalog/receipt use synchronous journal
/// operations under the journal's cross-process lock, with no suspension in that
/// window. Native operation drain happens first; the catalog is reread afterward.
@MainActor final class CloudCatalogBridge {
    private let profiles: PlusProfileController
    let journal: CloudSyncJournal
    private let deviceID: UUID
    let epoch: UUID
    private var active = true
    private var applying = false
    private var queued: [CloudCatalogCommit] = []
    private var applyPass: Task<Void, any Error>?
    private var localAdmissionPaused = false
    private(set) var failure: (any Error)?
    var onCommit: (@MainActor () -> Void)?

    init(profiles: PlusProfileController, journal: CloudSyncJournal, deviceID: UUID, epoch: UUID) {
        self.profiles = profiles; self.journal = journal; self.deviceID = deviceID; self.epoch = epoch
    }

    func attach() {
        profiles.onCatalogCommit = { [weak self] in self?.committed($0) }
        profiles.onCloudDraftReleased = { [weak self] in self?.onCommit?() }
        profiles.cloudCatalogWriteAdmission = { [weak self] in
            guard let self, self.active, !self.applying else { return }
            let state = try self.journal.catalogState()
            guard !state.receipts.values.contains(where: { $0.phase == .applying }), state.restoreIntent == nil else { throw CloudJournalError.applicationPending }
        }
    }

    func stop() {
        active = false
        applyPass?.cancel()
        profiles.onCatalogCommit = nil; profiles.cloudCatalogWriteAdmission = nil
        profiles.onCloudDraftReleased = nil
        // A failed/uncertain catalog receipt remains authoritative even after the
        // user disables sync. Do not let a new edit create an unreplayable third
        // digest; the next enabled bridge can finish recovery before admitting it.
        let journal = journal
        profiles.cloudCatalogWriteAdmission = {
            let state = try journal.catalogState()
            guard !state.receipts.values.contains(where: { $0.phase == .applying }), state.restoreIntent == nil else {
                throw CloudJournalError.applicationPending
            }
        }
    }

    func drainApplications() async { _ = try? await applyPass?.value }

    func committed(_ change: CloudCatalogCommit) {
        guard active, change.origin != .remote else { return }
        queued.append(change)
        guard !localAdmissionPaused else {
            do {
                try journal.catalogTransaction { state in
                    if change.origin == .local {
                        state.initialExplicitDeletedIDs = (state.initialExplicitDeletedIDs ?? []).union(change.explicitDeletedIDs)
                    }
                }
            } catch { failure = error }
            return
        }
        do {
            try drainCommits(); onCommit?()
        } catch { failure = error }
    }

    private func drainCommits() throws {
        do {
            while let next = queued.first {
                try journal.catalogTransaction { state in
                    try state.reconcile(.trusted(Self.projection(next.after)), deviceID: deviceID,
                                        inferDeletions: false, explicitDeletedIDs: next.origin == .local ? next.explicitDeletedIDs : [])
                }
                queued.removeFirst()
            }
            failure = nil
        } catch { failure = error; throw error }
    }

    func reconcileLocal(inferDeletions: Bool) throws {
        guard !localAdmissionPaused else { return }
        try drainCommits()
        try journal.catalogTransaction { state in
            try state.reconcile(profiles.cloudCatalogRead(), deviceID: deviceID, inferDeletions: inferDeletions)
        }
        failure = nil
    }

    func pauseLocalAdmission() throws {
        let current = try profiles.cloudCatalogRead().projection()
        try journal.catalogTransaction { state in
            if state.initialCatalogProjection == nil { state.initialCatalogProjection = current }
        }
        localAdmissionPaused = true
    }

    /// During first enable no baseline exists for distinguishing a remote field
    /// from a restored local copy. Seed it once under the union gate, preserving
    /// clocks/values already fetched; later writes use ordinary changed-field diff.
    func completeInitialUnion() throws {
        guard localAdmissionPaused else { return }
        let current = try profiles.cloudCatalogRead().projection()
        try journal.catalogTransaction { state in
            guard let baseline = state.initialCatalogProjection else { throw CloudJournalError.invalidState }
            state.committedProjection = baseline
            let queuedDeletes = queued.filter { $0.origin == .local }.reduce(into: Set<UUID>()) { $0.formUnion($1.explicitDeletedIDs) }
            try state.reconcile(.trusted(current), deviceID: deviceID, inferDeletions: false,
                                explicitDeletedIDs: (state.initialExplicitDeletedIDs ?? []).union(queuedDeletes))
            if state.order == nil, !current.profiles.isEmpty {
                let version = try CloudVersion.next(after: state.lamportCounter, observing: [], deviceID: deviceID)
                state.lamportCounter = version.counter
                let order = CloudOrderDocument(ids: current.profiles.map(\.id).filter {
                    state.profiles[CloudJournalState.profileRecordName($0)]?.tombstone == nil
                }, version: version)
                state.order = order
                try state.markDirty(recordName: CloudJournalState.orderRecordName, body: .order(order))
            }
            state.initialCatalogProjection = nil; state.initialExplicitDeletedIDs = nil
        }
        localAdmissionPaused = false
        queued.removeAll()
        failure = nil
    }

    /// Explicit restored tombstones become new identities. The remap and expected
    /// catalog digest are durable before writing; a crash retries the same UUIDs.
    func restoreUnion() throws {
        let current = try profiles.cloudCatalogRead().projection()
        let prepared = try journal.catalogTransaction { state -> (CloudRestoreIntent, [UUID: UUID]) in
            if let intent = state.restoreIntent, let remap = state.restoreProfileRemap { return (intent, remap) }
            let pendingCatalog = state.transport?.inboxOrder.contains { id in
                state.receivedEnvelopes[id].map { !$0.recordName.hasPrefix("session.") } == true &&
                    state.transport?.processedInbox.contains(id) != true
            } == true
            guard !pendingCatalog, state.transport?.blockedRecords.keys.contains(where: { !$0.hasPrefix("session.") }) != true else {
                // A missing key may hide a tombstone. Keep restore paused rather
                // than treating an undeciphered record as permission to reuse UUIDs.
                throw CloudJournalError.applicationPending
            }
            var remap: [UUID: UUID] = [:]
            for row in current.profiles where state.profiles[CloudJournalState.profileRecordName(row.id)]?.tombstone != nil {
                remap[row.id] = UUID()
            }
            let target = CloudCatalogProjection(profiles: current.profiles.map {
                .init(id: remap[$0.id] ?? $0.id, createdAt: $0.createdAt, values: $0.values)
            })
            let intent = CloudRestoreIntent(id: UUID(), expectedPreDigest: try current.digest(),
                expectedPostDigest: try target.digest(), postProjection: target)
            state.restoreIntent = intent; state.restoreProfileRemap = remap
            return (intent, remap)
        }
        let (intent, remap) = prepared
        guard profiles.cloudProtectedProfileIDs.isDisjoint(with: Set(remap.keys)) else { throw CloudJournalError.applicationPending }
        let digest = try current.digest()
        guard digest == intent.expectedPreDigest || digest == intent.expectedPostDigest else { throw CloudJournalError.catalogDiverged }
        if digest != intent.expectedPostDigest {
            applying = true
            defer { applying = false }
            _ = try profiles.applyCloudCatalog(intent.postProjection, remap: remap)
        }
        let committed = profiles.cloudCatalogRead()
        try journal.catalogTransaction { state in
            guard try committed.projection().digest() == intent.expectedPostDigest else { throw CloudJournalError.catalogDiverged }
            state.restoreIntent = nil
            // Existing credential snapshots are identity-keyed and remain in place.
            // Local queued session documents are copied to their new record names;
            // old generations remain retained under the tombstoned UUID.
            for session in Array(state.sessions.values) {
                guard let id = remap[session.profileID] else { continue }
                let mapped = CloudSessionDocument(profileID: id, sourceDeviceID: session.sourceDeviceID,
                    sourceName: session.sourceName, kind: session.kind, revision: session.revision,
                    capturedAt: session.capturedAt, payload: session.payload)
                let name = CloudRecordCodec.recordName(for: .session(mapped))
                if state.sessions[name] == nil { state.sessions[name] = mapped; try state.markDirty(recordName: name, body: .session(mapped)) }
            }
            try state.reconcile(committed, deviceID: deviceID, inferDeletions: false)
            state.restoreProfileRemap = nil
        }
    }

    /// Returns the latest merged journal view, never the raw delivered envelope.
    /// Processed, unapplied receipts are enumerated from disk even if all 16 stream
    /// notifications were dropped or the process restarted.
    func prepareNextReceipt() throws {
        let current = try profiles.cloudCatalogRead().projection()
        try journal.catalogTransaction { state in
            guard state.restoreIntent == nil else { throw CloudJournalError.applicationPending }
            guard !state.receipts.values.contains(where: { $0.phase == .applying }) else { return }
            guard let id = state.transport?.inboxOrder.first(where: {
                state.transport?.processedInbox.contains($0) == true && state.receipts[$0]?.phase == .received &&
                state.receivedEnvelopes[$0].map { !$0.recordName.hasPrefix("session.") } == true
            }) else { return }
            try state.reconcile(.trusted(current), deviceID: deviceID, inferDeletions: false)
            let target = Self.mergedProjection(current, state: state)
            let deleted = Set(current.profiles.map(\.id)).subtracting(target.profiles.map(\.id))
            guard profiles.cloudProtectedProfileIDs.isDisjoint(with: deleted) else { throw CloudJournalError.applicationPending }
            var documents = state.profiles.mapValues { CloudRecordBody.profile($0) }
            if let order = state.order { documents[CloudJournalState.orderRecordName] = .order(order) }
            try state.beginApplying(id, postProjection: target, documents: documents)
        }
    }

    @discardableResult
    func replayPending() throws -> [PlusProfile] {
        var removed: [PlusProfile] = []
        while let id = try journal.catalogState().receipts.first(where: { $0.value.phase == .applying })?.key {
            let read = profiles.cloudCatalogRead()
            let action = try journal.catalogTransaction { try $0.replay(id, catalog: read) }
            if case .needsApplication(let target) = action {
                applying = true
                defer { applying = false }
                removed += try profiles.applyCloudCatalog(target)
                let committed = profiles.cloudCatalogRead()
                _ = try journal.catalogTransaction { try $0.replay(id, catalog: committed) }
            }
        }
        try journal.compactCompletedCatalog()
        return removed
    }

    func applyRemote(profiles documents: [CloudProfileDocument], order: CloudOrderDocument?, epoch: UUID) async throws {
        // These inputs are notification hints only. The durable merged journal,
        // including later edits and receipts missed by the bounded stream, wins.
        guard active, self.epoch == epoch else { throw CloudTransportError.notStarted }
        if let applyPass { try await applyPass.value; return }
        let task = Task { try await self.applyRemoteIsolated(epoch: epoch) }
        applyPass = task
        defer { applyPass = nil }
        try await task.value
    }

    /// Recover saved pre/post images before any baseline reconciliation or fetch.
    /// This also runs while stopping for backup, after the transport has drained.
    func recoverPending() async throws {
        if let applyPass { try await applyPass.value }
        await profiles.prepareCloudCatalogApply()
        var removed: [PlusProfile] = []
        do {
            guard active, !Task.isCancelled else { throw CloudTransportError.notStarted }
            removed = try replayPending()
            if try journal.catalogState().restoreProfileRemap != nil { try restoreUnion() }
            await profiles.finishCloudCatalogApply(removed: removed)
        } catch {
            await profiles.finishCloudCatalogApply(removed: removed)
            throw error
        }
    }

    private func applyRemoteIsolated(epoch: UUID) async throws {
        await profiles.prepareCloudCatalogApply()
        var removed: [PlusProfile] = []
        do {
            guard active, self.epoch == epoch else { throw CloudTransportError.notStarted }
            removed += try replayPending()
            try reconcileLocal(inferDeletions: false)
            while true {
                try prepareNextReceipt()
                guard try journal.catalogState().receipts.values.contains(where: { $0.phase == .applying }) else { break }
                removed += try replayPending()
            }
            await profiles.finishCloudCatalogApply(removed: removed)
        } catch {
            await profiles.finishCloudCatalogApply(removed: removed)
            throw error
        }
    }

    static func projection(_ rows: [PlusProfile]) -> CloudCatalogProjection {
        .init(profiles: rows.map { .init(id: $0.id, createdAt: $0.createdAt, values: CloudProfileProjection.values(from: $0)) })
    }

    private static func mergedProjection(_ current: CloudCatalogProjection, state: CloudJournalState) -> CloudCatalogProjection {
        var rows = Dictionary(uniqueKeysWithValues: current.profiles.map { ($0.id, $0) })
        for document in state.profiles.values {
            if document.tombstone != nil { rows.removeValue(forKey: document.id); continue }
            var values = rows[document.id]?.values ?? .init(provider: "codex", label: "")
            let fields = document.fields
            if let field = fields.provider { values.provider = field.value }
            if let field = fields.label { values.label = field.value }
            if let field = fields.emailLink { values.emailLink = field.value }
            if let field = fields.password { values.password = field.value }
            if let field = fields.twoFactorCode { values.twoFactorCode = field.value }
            if let field = fields.phoneNumber { values.phoneNumber = field.value }
            if let field = fields.notes { values.notes = field.value }
            if let field = fields.tags { values.tags = field.value.filter { PlusProfileTag(rawValue: $0) != nil } }
            rows[document.id] = .init(id: document.id, createdAt: rows[document.id]?.createdAt ?? document.createdAt, values: values)
        }
        var ids = CloudProfileMerge.orderedIDs(state.order, profiles: Array(state.profiles.values))
        ids += current.profiles.map(\.id).filter { !ids.contains($0) }
        return .init(profiles: ids.compactMap { rows[$0] })
    }
}
