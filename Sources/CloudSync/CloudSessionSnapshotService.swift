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
            for other in sessions.values where other.profileID == document.profileID && other.kind == document.kind {
                guard let candidate = try? JSONDecoder().decode(CloudSessionPayload.self, from: other.payload).validated() else { continue }
                if candidate.consumed.contains(fingerprint) { return false }
            }
        }
        return !sessions.values.contains {
            $0.profileID == document.profileID && $0.kind == document.kind &&
                $0.sourceDeviceID == document.sourceDeviceID && $0.revision > document.revision
        }
    }
}
