import CloudKit
import Foundation

/// The only real network adapter. CKContainer and CKSyncEngine are created only by start.
actor CloudKitEngineDriver: CloudEngineDriving {
    private var engine: CKSyncEngine?
    private var delegate: CloudKitEngineDelegate?
    private let availability: CloudSyncAvailability
    private let makeContainer: @Sendable (String) throws -> CKContainer

    init(availability: CloudSyncAvailability = .init(),
         makeContainer: @escaping @Sendable (String) throws -> CKContainer = { CKContainer(identifier: $0) }) {
        self.availability = availability
        self.makeContainer = makeContainer
    }

    func start(owner: CloudOwner, state: Data?, callbacks: CloudEngineCallbacks) async throws {
        guard owner.container == CloudSyncAvailability.containerIdentifier else { throw CloudSyncAvailabilityError.unavailable }
        let container = try availability.withContainer(environment: owner.environment, factory: makeContainer)
        guard try await container.accountStatus() == .available,
              try await container.userRecordID().recordName == owner.userRecordName else { throw CloudTransportError.accountChanged }
        let serialization = try state.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let delegate = CloudKitEngineDelegate(owner: owner, callbacks: callbacks)
        let database = container.privateCloudDatabase
        let configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: delegate)
        self.delegate = delegate
        engine = CKSyncEngine(configuration)
    }

    func setPending(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        guard let engine else { return }
        CloudEnginePendingChanges.replace(in: engine.state, with: changes)
    }

    func createZone() { engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudRecordCodec.zoneID))]) }
    func fetchChanges() async throws { try await engine?.fetchChanges(.init(scope: .zoneIDs([CloudRecordCodec.zoneID]))) }
    func sendChanges() async throws { try await engine?.sendChanges(.init(scope: .zoneIDs([CloudRecordCodec.zoneID]))) }
    func cancelOperations() async {
        await delegate?.operations.close()
        await engine?.cancelOperations()
        // Apple's async cancellation return is not an operation completion barrier.
        await delegate?.operations.waitForCompletion()
        engine = nil; delegate = nil
    }
}

/// The installed SDK keeps one operation per record ID, with the last add winning.
/// This boundary lets synthetic tests apply the real adapter commands to that contract.
protocol CloudEnginePendingState: Sendable {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
}

extension CKSyncEngine.State: CloudEnginePendingState {}

enum CloudEnginePendingChanges {
    static func replace(in state: any CloudEnginePendingState, with changes: [CKSyncEngine.PendingRecordZoneChange]) {
        var byRecord: [CKRecord.ID: CKSyncEngine.PendingRecordZoneChange] = [:]
        for change in changes {
            switch change {
            case .deleteRecord(let id): byRecord[id] = change
            case .saveRecord(let id):
                if case .deleteRecord? = byRecord[id] { continue }
                byRecord[id] = change
            @unknown default: continue
            }
        }
        let old = Set(state.pendingRecordZoneChanges), desired = Set(byRecord.values)
        state.remove(pendingRecordZoneChanges: Array(old.subtracting(desired)))
        state.add(pendingRecordZoneChanges: Array(desired.subtracting(old)))
    }
}

final class CloudKitEngineDelegate: CKSyncEngineDelegate {
    private let owner: CloudOwner
    let callbacks: CloudEngineCallbacks
    let operations = CloudEngineOperationDrain()
    init(owner: CloudOwner, callbacks: CloudEngineCallbacks) { self.owner = owner; self.callbacks = callbacks }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            do { await callbacks.event(.state(try JSONEncoder().encode(update.stateSerialization))) }
            catch { await callbacks.event(.engineStateFailure) }
        case .accountChange(let change): await handleAccountChange(change.changeType)
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == CloudRecordCodec.zoneID }) { await callbacks.event(.zoneLost) }
        case .fetchedRecordZoneChanges(let changes):
            await callbacks.event(.fetched(records: changes.modifications.map(\.record), deletions: changes.deletions.map(\.recordID)))
        case .sentDatabaseChanges(let changes):
            for zone in changes.savedZones where zone.zoneID == CloudRecordCodec.zoneID { await callbacks.event(.zoneSaved(error: nil)) }
            for failure in changes.failedZoneSaves where failure.zone.zoneID == CloudRecordCodec.zoneID { await callbacks.event(.zoneSaved(error: failure.error)) }
        case .sentRecordZoneChanges(let changes):
            await callbacks.event(.sent(saved: changes.savedRecords,
                failed: changes.failedRecordSaves.map { .init(record: $0.record, error: $0.error) },
                deleted: changes.deletedRecordIDs, failedDeletes: changes.failedRecordDeletes))
        case .willFetchChanges:
            await operations.beginOperation()
            await callbacks.event(.fetchStarted)
        case .didFetchRecordZoneChanges(let changes):
            if changes.zoneID == CloudRecordCodec.zoneID { await callbacks.event(.zoneFetched(error: changes.error)) }
        case .didFetchChanges:
            // Completion only; this event deliberately does not certify fetch success.
            await callbacks.event(.fetchFinished)
            await operations.endOperation()
        case .didSendChanges:
            await callbacks.event(.sendFinished)
            await operations.endOperation()
        case .willSendChanges: await operations.beginOperation()
        case .willFetchRecordZoneChanges: break
        @unknown default: break
        }
    }

    func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) async {
        // A fresh engine reports the account already verified by start as a sign-in.
        // Only that exact owner is benign; sign-out/switch still revoke this epoch,
        // even when a switch's destination happens to match the verified owner.
        if case .signIn(let currentUser) = change, currentUser.recordName == owner.userRecordName { return }
        await callbacks.event(.accountChanged)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard await operations.canProvideBatch() else { return nil }
        return await callbacks.nextBatch(context.options.scope, syncEngine.state.pendingRecordZoneChanges)
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs(context.options.scope.contains(CloudRecordCodec.zoneID) ? [CloudRecordCodec.zoneID] : [])
        return options
    }
}
