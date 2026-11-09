import Foundation

struct CloudSessionSummary: Equatable, Sendable {
    let recordName: String
    let profileID: UUID
    let sourceDeviceID: UUID
    let sourceName: String
    let kind: CloudSessionKind
    let revision: UInt64
    let capturedAt: Date
    let identity: CloudSessionIdentity
}

/// Only explicit adoption code may request a candidate. UI uses summaries.
struct CloudSessionCandidate: Sendable {
    let summary: CloudSessionSummary
    let payload: CloudSessionPayload
}

actor CloudSessionInbox {
    private let journal: CloudSyncJournal
    private let keys: any CloudKeyStoring
    private let codec: CloudRecordCodec

    init(journal: CloudSyncJournal, keys: any CloudKeyStoring) {
        self.journal = journal; self.keys = keys
        // Decode never stages an outgoing asset or creates this directory.
        codec = .init(assets: .init(root: journal.paths.partition(for: journal.owner).appendingPathComponent("outgoing")))
    }

    func summaries(for profile: PlusProfile) async throws -> [CloudSessionSummary] {
        try await candidates(for: profile).map(\.summary)
    }

    func candidate(recordName: String, for profile: PlusProfile) async throws -> CloudSessionCandidate {
        guard let value = try await candidates(for: profile).first(where: { $0.summary.recordName == recordName }) else {
            throw CloudSessionError.unavailable
        }
        return value
    }

    private func candidates(for profile: PlusProfile) async throws -> [CloudSessionCandidate] {
        guard profile.provider == .codex else { return [] }
        let state = try await journal.load()
        guard Self.available(profile.id, in: state) else { return [] }
        var decoded: [CloudSessionCandidate] = []
        var highest: [String: UInt64] = [:]
        for stored in state.receivedEnvelopes.values where stored.recordName.hasPrefix("session.") {
            do {
                guard let (fresh, envelope, bytes) = try await journal.pendingInboxItem(stored.id), Self.available(profile.id, in: fresh),
                      fresh.transport?.deletedSessions.contains(envelope.recordName) != true else { continue }
                let routing = try JSONDecoder().decode(CloudRecordRouting.self, from: envelope.metadata)
                guard routing.kind == "session", routing.profileID == profile.id,
                      let key = try await keys.key(id: routing.keyID, owner: journal.owner) else { continue }
                let encrypted = CloudRecordEnvelope(id: envelope.id, recordName: envelope.recordName, routing: routing,
                    ciphertext: bytes, systemFields: envelope.systemFields)
                guard case .session(let document) = try codec.decode(encrypted, owner: journal.owner, key: key),
                      document.revision > 0, document.sourceName.utf8.count <= 1_024 else { continue }
                let source = "\(document.sourceDeviceID).\(document.kind.rawValue)"
                highest[source] = max(highest[source] ?? 0, document.revision)
                if let expected = fresh.transport?.sessionDigests[envelope.recordName],
                   expected != CloudJournalCoding.digest(try CloudJournalCoding.encode(document)) { continue }
                let payload = try JSONDecoder().decode(CloudSessionPayload.self, from: document.payload).validated()
                guard payload.kind == document.kind else { continue }
                let identity = try payload.identity
                try identity.validateBindings(of: profile)
                decoded.append(.init(summary: .init(recordName: envelope.recordName, profileID: document.profileID,
                    sourceDeviceID: document.sourceDeviceID, sourceName: document.sourceName, kind: document.kind,
                    revision: document.revision, capturedAt: document.capturedAt, identity: identity), payload: payload))
            } catch is CancellationError { throw CancellationError() }
            catch { continue } // Retain ciphertext for delayed keys / a later compatible reader.
        }
        // Arrival order and wall clocks never establish freshness. Every retained
        // source contributes consumed-generation evidence, including older revisions.
        let latest = Dictionary(grouping: decoded) { "\($0.summary.sourceDeviceID).\($0.summary.kind.rawValue)" }
        let current = try await journal.load()
        guard Self.available(profile.id, in: current) else { return [] }
        var result: [CloudSessionCandidate] = []
        for (source, values) in latest {
            guard let revision = values.map(\.summary.revision).max() else { continue }
            guard revision == highest[source] else { continue }
            let newest = values.filter { $0.summary.revision == revision }
            guard let item = newest.first,
                  try newest.allSatisfy({ try $0.payload.digest() == item.payload.digest() }) else { continue }
            var consumed = Set<String>()
            for other in decoded where other.summary.kind == item.summary.kind && other.summary.identity == item.summary.identity {
                consumed.formUnion(other.payload.consumed)
            }
            for local in current.sessions.values where local.profileID == profile.id && local.kind == item.summary.kind {
                if let payload = try? JSONDecoder().decode(CloudSessionPayload.self, from: local.payload).validated(),
                   try payload.identity == item.summary.identity { consumed.formUnion(payload.consumed) }
            }
            if let fingerprint = try item.payload.generationFingerprint,
               consumed.contains(fingerprint) || CloudSavedSessionChange.isConsumed(fingerprint, kind: item.summary.kind) { continue }
            guard current.transport?.deletedSessions.contains(item.summary.recordName) != true else { continue }
            result.append(item)
        }
        return result.sorted { $0.summary.recordName < $1.summary.recordName }
    }

    private static func available(_ id: UUID, in state: CloudJournalState) -> Bool {
        guard state.transport?.includeSavedSessions != false, state.restoreIntent == nil,
              let profile = state.profiles[CloudJournalState.profileRecordName(id)], profile.tombstone == nil,
              profile.fields.provider?.value == ProfileProvider.codex.rawValue else { return false }
        return true
    }
}
