import Darwin
import Foundation

/// No cached state: every operation locks and reloads, including after an uncertain rename.
/// The lock also prevents lost updates between multiple journal instances/processes.
actor CloudSyncJournal {
    static let maximumJournalBytes = 64 * 1_024 * 1_024
    static let maximumAssetBytes = 16 * 1_024 * 1_024
    let paths: CloudSyncPaths
    let owner: CloudOwner
    private let io: CloudJournalIO

    init(root: URL = CloudSyncPaths().root, owner: CloudOwner, io: CloudJournalIO = .init()) {
        paths = CloudSyncPaths(root: root)
        self.owner = owner
        self.io = io
    }

    func load() throws -> CloudJournalState {
        try withStorage { _, partition, inbox in try readState(partition: partition, inbox: inbox) }
    }

    func transaction<T: Sendable>(_ body: @Sendable (inout CloudJournalState) throws -> T) throws -> T {
        try withStorage { _, partition, inbox in
            let previous = try readState(partition: partition, inbox: inbox)
            var next = previous
            let result = try body(&next)
            try validateTransition(from: previous, to: next)
            try writeState(next, partition: partition, inbox: inbox)
            return result
        }
    }

    func deviceState() throws -> CloudSyncDeviceState {
        try withStorage { root, _, _ in try readDevice(root: root) }
    }

    func setPreferences(_ preferences: CloudSyncPreferences) throws {
        try withStorage { root, _, _ in
            var device = try readDevice(root: root)
            device.preferences = preferences
            try CloudPrivateFiles.replace("device.json", bytes: CloudJournalCoding.encode(device), in: root, io: io)
        }
    }

    /// The ciphertext is fsynced before its envelope or engine cursor can be published.
    /// A failed journal commit deliberately leaves the copied asset for recovery.
    @discardableResult
    func receive(id: UUID = UUID(), recordName: String, metadata: Data = Data(), systemFields: Data = Data(),
                 ciphertext: Data, engineState: Data? = nil) throws -> CloudReceivedEnvelope {
        guard !ciphertext.isEmpty, ciphertext.count <= Self.maximumAssetBytes else { throw CloudJournalError.tooLarge }
        guard !recordName.isEmpty else { throw CloudJournalError.invalidState }
        let asset = CloudCiphertextReference(fileName: id.uuidString.lowercased() + ".asset", byteCount: ciphertext.count,
                                            digest: CloudJournalCoding.digest(ciphertext))
        let envelope = CloudReceivedEnvelope(id: id, recordName: recordName, metadata: metadata, systemFields: systemFields, asset: asset)
        return try withStorage { _, partition, inbox in
            var state = try readState(partition: partition, inbox: inbox)
            if let existing = state.receivedEnvelopes[id] {
                guard existing == envelope else { throw CloudJournalError.invalidState }
            } else {
                guard state.receipts[id] == nil else { throw CloudJournalError.invalidTransition }
                state.receivedEnvelopes[id] = envelope
                state.receipts[id] = .init(phase: .received)
            }
            if let engineState { state.engineState = engineState }
            // Validate everything and bound the encoded state before mutating the inbox.
            try state.validate(expectedOwner: owner)
            _ = try encodedState(state)
            if let existing = try CloudPrivateFiles.read(asset.fileName, in: inbox, limit: Self.maximumAssetBytes) {
                guard existing == ciphertext else { throw CloudJournalError.assetMismatch }
                // This may be a retry after an uncertain asset rename.
                try confirmDurability(asset.fileName, in: inbox)
            } else {
                try CloudPrivateFiles.replace(asset.fileName, bytes: ciphertext, in: inbox, io: io)
            }
            try writeState(state, partition: partition, inbox: inbox)
            return envelope
        }
    }

    func ciphertext(for id: UUID) throws -> Data {
        try withStorage { _, partition, inbox in
            let state = try readState(partition: partition, inbox: inbox)
            guard let envelope = state.receivedEnvelopes[id] else { throw CloudJournalError.missingAsset }
            return try readAsset(envelope.asset, inbox: inbox)
        }
    }

    /// Unlink only after durable removal of the reference and a durable applied receipt.
    /// If replacement is uncertain, keep the bytes. Unreferenced crash leftovers are not auto-deleted.
    func removeAppliedEnvelope(_ id: UUID) throws {
        try withStorage { _, partition, inbox in
            var state = try readState(partition: partition, inbox: inbox)
            guard state.receipts[id]?.phase == .applied else { throw CloudJournalError.invalidTransition }
            guard let envelope = state.receivedEnvelopes.removeValue(forKey: id) else { return }
            try writeState(state, partition: partition, inbox: inbox)
            try CloudPrivateFiles.remove(envelope.asset.fileName, in: inbox)
        }
    }

    private func readState(partition: Int32, inbox: Int32) throws -> CloudJournalState {
        guard let bytes = try CloudPrivateFiles.read("journal.json", in: partition, limit: Self.maximumJournalBytes) else {
            return CloudJournalState(owner: owner)
        }
        let state = try CloudJournalCoding.decode(CloudJournalState.self, from: bytes)
        try state.validate(expectedOwner: owner)
        try validateAssets(state, inbox: inbox)
        // A prior process may have renamed successfully but failed its parent fsync.
        // Do not return a usable receipt/cursor until the visible commit is durable.
        try confirmDurability("journal.json", in: partition)
        return state
    }

    private func writeState(_ state: CloudJournalState, partition: Int32, inbox: Int32) throws {
        try state.validate(expectedOwner: owner)
        try validateAssets(state, inbox: inbox)
        for envelope in state.receivedEnvelopes.values {
            try confirmDurability(envelope.asset.fileName, in: inbox)
        }
        try CloudPrivateFiles.replace("journal.json", bytes: encodedState(state), in: partition, io: io)
    }

    private func encodedState(_ state: CloudJournalState) throws -> Data {
        let bytes = try CloudJournalCoding.encode(state)
        guard bytes.count <= Self.maximumJournalBytes else { throw CloudJournalError.tooLarge }
        return bytes
    }

    private func validateAssets(_ state: CloudJournalState, inbox: Int32) throws {
        for envelope in state.receivedEnvelopes.values { _ = try readAsset(envelope.asset, inbox: inbox) }
    }

    private func readAsset(_ reference: CloudCiphertextReference, inbox: Int32) throws -> Data {
        guard let bytes = try CloudPrivateFiles.read(reference.fileName, in: inbox, limit: Self.maximumAssetBytes) else {
            throw CloudJournalError.missingAsset
        }
        guard bytes.count == reference.byteCount, CloudJournalCoding.digest(bytes) == reference.digest else {
            throw CloudJournalError.assetMismatch
        }
        return bytes
    }

    private func readDevice(root: Int32) throws -> CloudSyncDeviceState {
        if let bytes = try CloudPrivateFiles.read("device.json", in: root, limit: 16_384) {
            let device = try CloudJournalCoding.decode(CloudSyncDeviceState.self, from: bytes)
            try confirmDurability("device.json", in: root)
            return device
        }
        let device = CloudSyncDeviceState(deviceID: UUID())
        try CloudPrivateFiles.replace("device.json", bytes: CloudJournalCoding.encode(device), in: root, io: io)
        return device
    }

    private func confirmDurability(_ name: String, in directory: Int32) throws {
        do {
            try io.before(.recoverySync, name)
            try CloudPrivateFiles.synchronize(name, in: directory)
        } catch { throw CloudJournalError.commitUncertain(name) }
    }

    private func validateTransition(from previous: CloudJournalState, to next: CloudJournalState) throws {
        guard next.lamportCounter >= previous.lamportCounter else { throw CloudJournalError.invalidState }
        for (name, generation) in previous.recordGenerations {
            guard (next.recordGenerations[name] ?? 0) >= generation else { throw CloudJournalError.invalidState }
        }
        for (id, receipt) in previous.receipts {
            guard let replacement = next.receipts[id] else { throw CloudJournalError.invalidTransition }
            switch receipt.phase {
            case .received:
                guard replacement.phase != .applied else { throw CloudJournalError.invalidTransition }
            case .applying:
                guard replacement.phase != .received, replacement.plan == receipt.plan else { throw CloudJournalError.invalidTransition }
            case .applied:
                guard replacement == receipt else { throw CloudJournalError.invalidTransition }
            }
        }
        for (id, envelope) in previous.receivedEnvelopes {
            if let replacement = next.receivedEnvelopes[id] {
                guard replacement == envelope else { throw CloudJournalError.invalidState }
            } else if next.receipts[id]?.phase != .applied { throw CloudJournalError.invalidTransition }
        }
        for (name, document) in previous.profiles where document.tombstone != nil {
            guard next.profiles[name]?.tombstone != nil else { throw CloudJournalError.invalidState }
        }
    }

    private func withStorage<T>(_ body: (Int32, Int32, Int32) throws -> T) throws -> T {
        guard !owner.container.isEmpty, !owner.userRecordName.isEmpty else { throw CloudJournalError.invalidState }
        let root = try CloudPrivateFiles.openRoot(paths.root, io: io)
        defer { close(root) }
        let lock = try CloudPrivateFiles.lock(in: root)
        defer { flock(lock, LOCK_UN); close(lock) }
        let owners = try CloudPrivateFiles.directory("owners", in: root, io: io)
        defer { close(owners) }
        let partition = try CloudPrivateFiles.directory(CloudSyncPaths.ownerDigest(owner), in: owners, io: io)
        defer { close(partition) }
        let inbox = try CloudPrivateFiles.directory("inbox", in: partition, io: io)
        defer { close(inbox) }
        return try body(root, partition, inbox)
    }
}
