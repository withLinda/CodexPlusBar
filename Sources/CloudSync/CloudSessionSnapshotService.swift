import Foundation

protocol CloudSavedSessionCapturing: Sendable {
    func captureSavedSession(for profile: PlusProfile) async throws -> CloudSessionPayload?
}

extension CloudSavedSessionCapturing {
    func captureSavedSession(for profile: PlusProfile) async throws -> CloudSessionPayload? { nil }
}

/// Providers own their existing serialization/maintenance boundaries. A failed
/// provider cannot erase another provider's last good snapshot or block metadata.
@MainActor final class CloudSessionSnapshotService {
    typealias Provider = @MainActor (PlusProfile) async throws -> CloudSessionPayload?
    private let providers: [Provider]
    private let readRevision: @MainActor () -> UInt64
    var revision: UInt64 { readRevision() }
    init(providers: [Provider], revision: @escaping @MainActor () -> UInt64 = { CloudSavedSessionChange.revision }) {
        self.providers = providers; readRevision = revision
    }

    func capture(for profile: PlusProfile) async throws -> [CloudSessionPayload] {
        guard profile.provider == .codex else { return [] }
        var result: [CloudSessionPayload] = []
        for provider in providers {
            try Task.checkCancellation()
            do {
                if let payload = try await provider(profile) {
                    let validated = try payload.validated()
                    try validated.identity.validateBindings(of: profile)
                    result.append(validated)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return result
    }
}

/// Durable-store notifications are hints. They carry no credentials. A read is
/// always admitted through the owning service after its write gate is released.
enum CloudSavedSessionChange {
    private final class Generation: @unchecked Sendable {
        let lock = NSLock()
        var value: UInt64 = 0
        var consumed: Set<String> = []
    }
    private static let generation = Generation()
    static var revision: UInt64 { generation.lock.withLock { generation.value } }
    static let notification = Notification.Name("CodexPlusBar.savedSessionCommitted")
    static func committed() {
        generation.lock.withLock { generation.value &+= 1 }
    }
    /// Only operation owners emit this after leaving their serialization gate.
    static func released() { NotificationCenter.default.post(name: notification, object: nil) }
    static func consumed(_ fingerprint: String, kind: CloudSessionKind) {
        generation.lock.withLock { _ = generation.consumed.insert(kind.rawValue + "." + fingerprint) }
        committed()
    }
    static func isConsumed(_ fingerprint: String, kind: CloudSessionKind) -> Bool {
        generation.lock.withLock { generation.consumed.contains(kind.rawValue + "." + fingerprint) }
    }
}

final class CloudSessionChangeObserver: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ changed: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: CloudSavedSessionChange.notification, object: nil, queue: nil) { _ in changed() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

extension CloudJournalState {
    static func sessionSourceKey(_ profileID: UUID, _ sourceDeviceID: UUID, _ kind: CloudSessionKind) -> String {
        "\(profileID.uuidString).\(sourceDeviceID.uuidString).\(kind.rawValue)"
    }

    func latestSessionRevision(profileID: UUID, sourceDeviceID: UUID, kind: CloudSessionKind) -> UInt64 {
        max(sessionRevisionHighWater?[Self.sessionSourceKey(profileID, sourceDeviceID, kind)] ?? 0,
            sessions.values.filter { $0.profileID == profileID && $0.sourceDeviceID == sourceDeviceID && $0.kind == kind }
                .map(\.revision).max() ?? 0)
    }

    /// Atomic journal-only compaction. Active sends own a value-copy of the exact
    /// document plus their ciphertext lease in Flight until ack/cancellation drains.
    /// No send reloads its body by name after admission. Restart publishes only the
    /// retained latest capture after store reconciliation; old cloud copies remain.
    mutating func compactLocalSessions() {
        var latest: [String: UInt64] = sessionRevisionHighWater ?? [:]
        for document in sessions.values {
            let source = Self.sessionSourceKey(document.profileID, document.sourceDeviceID, document.kind)
            latest[source] = max(latest[source] ?? 0, document.revision)
            rememberSessionConsumption(document)
            // A send may have reached CloudKit before its ack reached disk.
            // Preserve exact names for later explicit tombstone cleanup.
            if transport == nil { transport = .init() }
            transport?.sessionProfiles[CloudRecordCodec.recordName(for: .session(document))] = document.profileID
        }
        if !latest.isEmpty { sessionRevisionHighWater = latest }
        for (name, document) in sessions {
            let source = Self.sessionSourceKey(document.profileID, document.sourceDeviceID, document.kind)
            guard document.revision < (latest[source] ?? 0) else { continue }
            sessions.removeValue(forKey: name)
            dirtyGenerations.removeValue(forKey: name)
            transport?.validatedSessionRecords?.remove(name)
            // Keep generation/digest and cloud deletion/replay indexes. Never
            // touch received envelopes, receipts, assets or remote deletion queues.
        }
    }

    static func sessionIdentityScope(_ profileID: UUID, _ kind: CloudSessionKind, _ identity: CloudSessionIdentity) throws -> String {
        CloudSessionPayload.fingerprint(String(decoding: try CloudJournalCoding.encode(
            [profileID.uuidString, kind.rawValue, identity.accountID, identity.userID]), as: UTF8.self))
    }

    /// Call only for validated local capture or authenticated codec output. JWT
    /// claims alone, routing fields and opaque/future payloads never add evidence.
    mutating func rememberSessionConsumption(_ document: CloudSessionDocument) {
        guard document.revision > 0, document.sourceName.utf8.count <= 1_024,
              let payload = try? JSONDecoder().decode(CloudSessionPayload.self, from: document.payload).validated(),
              payload.kind == document.kind, !payload.consumed.isEmpty,
              let scope = try? Self.sessionIdentityScope(document.profileID, document.kind, payload.identity) else { return }
        if consumedSessionGenerations == nil { consumedSessionGenerations = [:] }
        consumedSessionGenerations?[scope, default: []].formUnion(payload.consumed)
    }

    func consumedSessionFingerprints(profileID: UUID, payload: CloudSessionPayload) throws -> Set<String> {
        consumedSessionGenerations?[try Self.sessionIdentityScope(profileID, payload.kind, payload.identity)] ?? []
    }

    func canPublishSession(_ document: CloudSessionDocument) -> Bool {
        let name = CloudRecordCodec.recordName(for: .session(document))
        guard transport?.validatedSessionRecords?.contains(name) != false else { return false }
        guard profiles[Self.profileRecordName(document.profileID)]?.tombstone == nil else { return false }
        if let provider = profiles[Self.profileRecordName(document.profileID)]?.fields.provider?.value, provider != ProfileProvider.codex.rawValue { return false }
        guard let decoded = try? JSONDecoder().decode(CloudSessionPayload.self, from: document.payload) else {
            // The transport is schema-neutral; unknown payloads are never executable
            // in CloudSessionInbox. Preserve compatibility with retained documents.
            return true
        }
        guard let payload = try? decoded.validated(), payload.kind == document.kind else { return false }
        if let fingerprint = try? payload.generationFingerprint {
            if CloudSavedSessionChange.isConsumed(fingerprint, kind: document.kind) { return false }
            if (try? consumedSessionFingerprints(profileID: document.profileID, payload: payload).contains(fingerprint)) == true { return false }
            for other in sessions.values where other.profileID == document.profileID && other.kind == document.kind {
                guard let candidate = try? JSONDecoder().decode(CloudSessionPayload.self, from: other.payload).validated(),
                      candidate.kind == document.kind, (try? candidate.identity) == (try? payload.identity) else { continue }
                if candidate.consumed.contains(fingerprint) { return false }
            }
        }
        return document.revision >= latestSessionRevision(profileID: document.profileID,
            sourceDeviceID: document.sourceDeviceID, kind: document.kind)
    }
}
