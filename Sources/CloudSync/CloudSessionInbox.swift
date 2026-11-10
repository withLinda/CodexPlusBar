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
    var validationStamp: Data? = nil
    var consumedFingerprints: Set<String> = []
    var sourceConsumed = false
}

extension CloudJournalState {
    /// Conservative fence: even an unreadable new envelope invalidates a read.
    /// Unauthenticated routing cannot hide an arrival from final admission.
    func sessionInboxStamp(for profileID: UUID) throws -> Data {
        // Sets and UUID-keyed dictionaries have no canonical JSON order. Encode
        // sorted arrays instead through an ordinary string-keyed representation.
        var object: [String: Data] = [:]
        for (id, envelope) in receivedEnvelopes where envelope.recordName.hasPrefix("session.") {
            object["envelope." + id.uuidString] = try CloudJournalCoding.encode(envelope)
        }
        object["digests"] = try CloudJournalCoding.encode(transport?.sessionDigests ?? [:])
        object["deleted"] = try CloudJournalCoding.encode((transport?.deletedSessions ?? []).sorted())
        object["local"] = try CloudJournalCoding.encode(sessions.filter { $0.value.profileID == profileID })
        object["profile"] = try CloudJournalCoding.encode(profiles[Self.profileRecordName(profileID)])
        object["includes"] = try CloudJournalCoding.encode(transport?.includeSavedSessions != false)
        object["restore"] = try CloudJournalCoding.encode(restoreIntent)
        object["consumed"] = try CloudJournalCoding.encode((consumedSessionGenerations ?? [:]).mapValues { $0.sorted() })
        return CloudJournalCoding.digest(try CloudJournalCoding.encode(object))
    }
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

    func candidate(recordName: String, for profile: PlusProfile, recovering: Bool = false) async throws -> CloudSessionCandidate {
        guard let value = try await candidates(for: profile, recovering: recovering).first(where: { $0.summary.recordName == recordName }) else {
            throw CloudSessionError.unavailable
        }
        return value
    }

    private func candidates(for profile: PlusProfile, recovering: Bool = false) async throws -> [CloudSessionCandidate] {
        guard profile.provider == .codex else { return [] }
        let state = try await journal.load()
        guard Self.available(profile.id, in: state) else { return [] }
        let stamp = try state.sessionInboxStamp(for: profile.id)
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
                if let expected = fresh.payloadDigests[envelope.recordName],
                   expected != CloudJournalCoding.digest(try CloudJournalCoding.encode(CloudRecordBody.session(document))) { continue }
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
        // Synchronous flock-backed reload is the linearization point. Do not
        // retry indefinitely under arrivals; a caller may request a fresh read.
        let current = try journal.catalogState()
        guard Self.available(profile.id, in: current), try current.sessionInboxStamp(for: profile.id) == stamp else { return [] }
        var result: [CloudSessionCandidate] = []
        for (source, values) in latest {
            guard let revision = values.map(\.summary.revision).max() else { continue }
            guard revision == highest[source] else { continue }
            let newest = values.filter { $0.summary.revision == revision }
            guard var item = newest.first,
                  try newest.allSatisfy({ try $0.payload.digest() == item.payload.digest() }) else { continue }
            var consumed = try current.consumedSessionFingerprints(profileID: profile.id, payload: item.payload)
            for other in decoded where other.summary.kind == item.summary.kind && other.summary.identity == item.summary.identity {
                consumed.formUnion(other.payload.consumed)
            }
            for local in current.sessions.values where local.profileID == profile.id && local.kind == item.summary.kind {
                if let payload = try? JSONDecoder().decode(CloudSessionPayload.self, from: local.payload).validated(),
                   try payload.identity == item.summary.identity { consumed.formUnion(payload.consumed) }
            }
            if let fingerprint = try item.payload.generationFingerprint {
                item.sourceConsumed = consumed.contains(fingerprint) || CloudSavedSessionChange.isConsumed(fingerprint, kind: item.summary.kind)
                if item.sourceConsumed, !recovering { continue }
            }
            item.consumedFingerprints = consumed
            guard current.transport?.deletedSessions.contains(item.summary.recordName) != true else { continue }
            item.validationStamp = stamp
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
