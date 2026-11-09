import Darwin
import Foundation

struct CloudOwnerConsent: Codable, Equatable, Sendable {
    let owner: CloudOwner
    var enabled: Bool
    var includeSavedSessions: Bool
}

struct CloudTransferPause: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case preparing, commitAttempted }
    let id: UUID
    let restoring: Bool
    var phase: Phase
    let previouslyEnabled: Bool
    let previouslyPaused: Bool
    let owner: CloudOwner?
}

struct CloudSyncPreferences: Codable, Equatable, Sendable {
    /// Device-level intent permits an identity lookup only after the entitlement gate.
    /// It never authorizes a partition on its own, including migrated schema-1 data.
    var enabled: Bool
    var paused: Bool
    var includeSavedSessions: Bool
    private(set) var previousActiveOwner: CloudOwner?
    private(set) var ownerConsents: [String: CloudOwnerConsent]
    private(set) var transferPause: CloudTransferPause?

    init(enabled: Bool = false, paused: Bool = false, includeSavedSessions: Bool = true) {
        self.enabled = enabled
        self.paused = paused
        self.includeSavedSessions = includeSavedSessions
        previousActiveOwner = nil
        ownerConsents = [:]
        transferPause = nil
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, paused, includeSavedSessions, previousActiveOwner, ownerConsents, transferPause
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        includeSavedSessions = try container.decodeIfPresent(Bool.self, forKey: .includeSavedSessions) ?? true
        previousActiveOwner = try container.decodeIfPresent(CloudOwner.self, forKey: .previousActiveOwner)
        ownerConsents = try container.decodeIfPresent([String: CloudOwnerConsent].self, forKey: .ownerConsents) ?? [:]
        transferPause = try container.decodeIfPresent(CloudTransferPause.self, forKey: .transferPause)
        try validate()
    }

    func canResume(for owner: CloudOwner) -> Bool {
        enabled && !paused && transferPause == nil && previousActiveOwner == owner && consent(for: owner)?.enabled == true
    }

    func includesSessions(for owner: CloudOwner) -> Bool {
        consent(for: owner)?.includeSavedSessions ?? true
    }

    /// Only an explicit user action may change the active owner binding.
    mutating func setConsent(enabled: Bool, for owner: CloudOwner) {
        let includes = includesSessions(for: owner)
        ownerConsents[CloudSyncPaths.ownerDigest(owner)] = .init(owner: owner, enabled: enabled, includeSavedSessions: includes)
        if enabled {
            previousActiveOwner = owner
            self.enabled = true
            includeSavedSessions = includes
        } else if previousActiveOwner == owner {
            self.enabled = false
        }
    }

    /// Persist this before opening any owner partition. Previously granted consent
    /// for a returning account is insufficient after an account switch.
    mutating func observeOwner(_ owner: CloudOwner) {
        if previousActiveOwner != owner { enabled = false }
    }

    mutating func setIncludesSessions(_ includes: Bool, for owner: CloudOwner) {
        var consent = consent(for: owner) ?? .init(owner: owner, enabled: false, includeSavedSessions: true)
        consent.includeSavedSessions = includes
        ownerConsents[CloudSyncPaths.ownerDigest(owner)] = consent
        if previousActiveOwner == owner { includeSavedSessions = includes }
    }

    /// Persist before draining native transfer gates. The caller still owns
    /// stopping/draining transport and catalog admission before touching backup data.
    mutating func beginTransfer(restoring: Bool) throws {
        guard transferPause == nil else { throw CloudJournalError.applicationPending }
        transferPause = .init(id: UUID(), restoring: restoring, phase: .preparing,
                              previouslyEnabled: enabled, previouslyPaused: paused, owner: previousActiveOwner)
        paused = true
    }

    /// Persist immediately before calling BackupService.commit. A thrown commit
    /// cannot establish whether a tree replacement occurred.
    mutating func markRestoreCommitAttempt() throws {
        guard transferPause?.restoring == true, transferPause?.phase == .preparing else {
            throw CloudJournalError.invalidTransition
        }
        transferPause?.phase = .commitAttempted
    }

    mutating func finishTransfer(restored: Bool) {
        guard let pause = transferPause else { return }
        if restored || pause.phase == .commitAttempted {
            paused = true
            return
        }
        paused = pause.previouslyPaused
        // A disable/account change during the transfer must not be undone.
        enabled = enabled && pause.previouslyEnabled && previousActiveOwner == pause.owner
        transferPause = nil
    }

    /// Called only after an explicitly requested full fetch/union and durable
    /// catalog/UUID-remap recovery. Merely toggling consent cannot clear this pause.
    mutating func completeRestoreUnion(for owner: CloudOwner) throws {
        guard previousActiveOwner == owner, enabled else { throw CloudJournalError.ownerMismatch }
        paused = false; transferPause = nil
    }

    func validate() throws {
        if let transferPause {
            guard paused, transferPause.phase != .commitAttempted || transferPause.restoring else {
                throw CloudJournalError.invalidState
            }
        }
        if let previousActiveOwner {
            guard !previousActiveOwner.container.isEmpty, !previousActiveOwner.userRecordName.isEmpty else { throw CloudJournalError.invalidState }
        }
        for (key, consent) in ownerConsents {
            guard !consent.owner.container.isEmpty, !consent.owner.userRecordName.isEmpty,
                  key == CloudSyncPaths.ownerDigest(consent.owner) else { throw CloudJournalError.invalidState }
        }
    }

    private func consent(for owner: CloudOwner) -> CloudOwnerConsent? {
        let value = ownerConsents[CloudSyncPaths.ownerDigest(owner)]
        return value?.owner == owner ? value : nil
    }
}

/// Independent of all owner partitions and outside the backup tree. Construction
/// and `read` are inert: no directory, lock, identity, Keychain or cloud work.
/// Mutations use the journal's cross-process root lock and durable private I/O.
struct CloudSyncPreferencesStore: Sendable {
    static let maximumBytes = 16_384
    let paths: CloudSyncPaths
    private let io: CloudJournalIO

    init(root: URL = CloudSyncPaths().root, io: CloudJournalIO = .init()) {
        paths = CloudSyncPaths(root: root)
        self.io = io
    }

    func read() throws -> CloudSyncDeviceState? {
        let root: Int32
        do { root = try CloudPrivateFiles.openRoot(paths.root, io: io, create: false) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        defer { close(root) }
        return try read(in: root)
    }

    @discardableResult
    func update(_ body: (inout CloudSyncPreferences) throws -> Void) throws -> CloudSyncDeviceState {
        let root = try CloudPrivateFiles.openRoot(paths.root, io: io)
        defer { close(root) }
        let lock = try CloudPrivateFiles.lock(in: root)
        defer { flock(lock, LOCK_UN); close(lock) }
        let previous = try read(in: root)
        if previous != nil {
            do {
                try io.before(.recoverySync, "device.json")
                try CloudPrivateFiles.synchronize("device.json", in: root)
            } catch { throw CloudJournalError.commitUncertain("device.json") }
        }
        var device = previous ?? CloudSyncDeviceState(deviceID: UUID())
        try body(&device.preferences)
        try device.preferences.validate()
        if device != previous {
            let bytes = try CloudJournalCoding.encode(device)
            guard bytes.count <= Self.maximumBytes else { throw CloudJournalError.tooLarge }
            try CloudPrivateFiles.replace("device.json", bytes: bytes, in: root, io: io)
        }
        return device
    }

    private func read(in root: Int32) throws -> CloudSyncDeviceState? {
        guard let bytes = try CloudPrivateFiles.read("device.json", in: root, limit: Self.maximumBytes) else { return nil }
        return try CloudJournalCoding.decode(CloudSyncDeviceState.self, from: bytes)
    }
}
