import CloudKit
import Foundation

protocol CloudSyncTransport: Sendable {
    var events: AsyncStream<CloudTransportEvent> { get }
    func start(owner: CloudOwner, epoch: UUID) async throws
    func syncNow() async throws
    func stop() async
}

struct CloudTransportEvent: Sendable {
    let owner: CloudOwner
    let epoch: UUID
    let value: Value
    enum Value: Sendable {
        case received([CloudRecordEnvelope])
        case sent([CloudSentRevision])
        case accountChanged
        case status(CloudTransportStatus)
    }
}

enum CloudTransportStatus: Equatable, Sendable {
    case syncing, upToDate
    case waitingForKey(String), quarantined(String), retrying(String), quota(String), itemFailure(String)
    case paused(CloudTransportError)
}

enum CloudTransportError: Error, Equatable, Sendable {
    case notStarted, zoneLost, storageFailure, accountChanged, invalidRecord, fetchRequired
}

/// The production delegate maps SDK events into this boundary. Tests replace only the engine.
enum CloudEngineEvent: Sendable {
    case state(Data)
    case fetched(records: [CKRecord], deletions: [CKRecord.ID])
    case zoneFetched(error: CKError?)
    case zoneSaved(error: CKError?)
    case zoneLost, accountChanged, fetchStarted, fetchFinished, sendFinished, engineStateFailure
    case sent(saved: [CKRecord], failed: [CloudEngineRecordFailure], deleted: [CKRecord.ID], failedDeletes: [CKRecord.ID: CKError])
}

struct CloudEngineRecordFailure: Sendable {
    let record: CKRecord
    let error: CKError
}

struct CloudEngineCallbacks: Sendable {
    let event: @Sendable (CloudEngineEvent) async -> Void
    let nextBatch: @Sendable (CKSyncEngine.SendChangesOptions.Scope, [CKSyncEngine.PendingRecordZoneChange]) async -> CKSyncEngine.RecordZoneChangeBatch?
}

protocol CloudEngineDriving: Sendable {
    func start(owner: CloudOwner, state: Data?, callbacks: CloudEngineCallbacks) async throws
    func setPending(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
    func createZone() async
    func fetchChanges() async throws
    func sendChanges() async throws
    /// Returns only after operation callbacks have drained.
    func cancelOperations() async
}

struct CloudTransportJournalState: Codable, Equatable, Sendable {
    // Optional for journals created before coordinator admission existed.
    var catalogPublicationPaused: Bool?
    var includeSavedSessions: Bool?
    /// Coordinator clears this on every owner run. Retained snapshots become
    /// sendable only after saved-store recovery has resolved them in that run.
    var validatedSessionRecords: Set<String>?
    var initialized = false
    var zoneEstablished = false
    var zoneCreationRequested = false
    var zoneLost = false
    var inboxOrder: [UUID] = []
    var processedInbox: Set<UUID> = []
    var blockedRecords: [String: CloudRecordBlock] = [:]
    var retryAfter: [String: Date] = [:]
    var sessionProfiles: [String: UUID] = [:]
    var sessionDigests: [String: Data] = [:]
    var sessionReceipts: [String: UUID] = [:]
    var acknowledgedTombstones: Set<UUID> = []
    var pendingSessionDeletes: Set<String> = []
    var deletedSessions: Set<String> = []

    func validate(in state: CloudJournalState) throws {
        guard Set(inboxOrder).count == inboxOrder.count,
              validatedSessionRecords?.allSatisfy({ state.sessions[$0] != nil }) != false,
              inboxOrder.allSatisfy({ state.receipts[$0] != nil }),
              processedInbox.isSubset(of: Set(inboxOrder)),
              pendingSessionDeletes.allSatisfy({ sessionProfiles[$0] != nil }),
              sessionProfiles.keys.allSatisfy({ $0.hasPrefix("session.") }),
              sessionDigests.values.allSatisfy({ $0.count == 32 }),
              sessionReceipts.values.allSatisfy({ processedInbox.contains($0) }),
              retryAfter.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw CloudJournalError.invalidState }
    }
}

/// CKSyncEngine.cancelOperations() may return before operations complete. Closing gates
/// new batch providers; terminal will/did pairs, not the cancellation return, drain leases.
actor CloudEngineOperationDrain {
    private var closing = false
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func canProvideBatch() -> Bool { !closing }
    func beginOperation() { active += 1 }
    func endOperation() {
        active = max(0, active - 1)
        if active == 0 {
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    func close() { closing = true }
    func waitForCompletion() async {
        if active > 0 { await withCheckedContinuation { waiters.append($0) } }
    }
}

enum CloudRecordBlock: String, Codable, Sendable {
    case invalid, quota, permanent, deleted
}

/// Serializes complete async operations, not just their individual actor turns.
/// A delegate state update cannot overtake the preceding inbox fsync during an await.
actor CloudTransportSerial {
    private var tail: Task<Void, Never>?
    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let operation = Task { await previous?.value; return try await body() }
        tail = Task { _ = try? await operation.value }
        return try await operation.value
    }
}
