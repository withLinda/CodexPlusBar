import CryptoKit
import Foundation

enum CloudJournalError: Error, Equatable, Sendable, LocalizedError {
    case unsafePath, tooLarge, corruptState, ownerMismatch, invalidState
    case unsupportedSchema(Int)
    case catalogUnavailable, catalogDiverged, applicationPending, invalidTransition
    case missingAsset, assetMismatch
    /// Rename succeeded. Reload before deciding what to retry; this is NOT a rollback.
    case commitUncertain(String)

    var errorDescription: String? {
        switch self {
        case .corruptState, .invalidState: "Cloud sync state is damaged or inconsistent. Preserve the journal for recovery."
        case .unsupportedSchema: "Cloud sync state requires a different app version."
        case .unsafePath: "Cloud sync storage must use private, regular files outside the account folder."
        case .tooLarge: "Cloud sync data exceeds its storage limit."
        case .ownerMismatch: "Cloud sync state belongs to another iCloud owner or environment."
        case .catalogUnavailable: "The committed account catalog cannot be read. Sync has not inferred any deletions."
        case .catalogDiverged: "The account catalog differs from both sides of the pending cloud apply."
        case .applicationPending, .invalidTransition: "A pending cloud apply must be reconciled before continuing."
        case .missingAsset, .assetMismatch: "A received cloud asset is missing or damaged. Preserve the inbox for recovery."
        case .commitUncertain: "Cloud sync replacement completed but its durability could not be confirmed. Reload before retrying."
        }
    }
}

enum CloudJournalCoding {
    private struct Header: Decodable { let schemaVersion: Int }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        do {
            let header = try JSONDecoder().decode(Header.self, from: bytes)
            guard header.schemaVersion == 1 else { throw CloudJournalError.unsupportedSchema(header.schemaVersion) }
            return try JSONDecoder().decode(type, from: bytes)
        } catch let error as CloudJournalError { throw error }
        catch { throw CloudJournalError.corruptState }
    }
}

struct CloudCommittedProfile: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let values: CloudProfileValues
}

/// Ordered, allowlisted catalog snapshot, supplied only after a successful catalog commit/read.
struct CloudCatalogProjection: Codable, Equatable, Sendable {
    let profiles: [CloudCommittedProfile]

    func validate() throws {
        guard profiles.count <= 10_000, Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite }) else { throw CloudJournalError.invalidState }
    }

    func digest() throws -> Data {
        try validate()
        return CloudJournalCoding.digest(try CloudJournalCoding.encode(self))
    }
}

enum CloudCatalogRead: Sendable {
    case trusted(CloudCatalogProjection)
    case missing
    case unreadable

    func projection() throws -> CloudCatalogProjection {
        guard case .trusted(let projection) = self else { throw CloudJournalError.catalogUnavailable }
        try projection.validate()
        return projection
    }
}

struct CloudSentRevision: Codable, Equatable, Sendable {
    let recordName: String
    let generation: UInt64
    let payloadDigest: Data
}

struct CloudCiphertextReference: Codable, Equatable, Sendable {
    let fileName: String
    let byteCount: Int
    let digest: Data
}

/// Transport metadata stays opaque until the codec/CloudKit boundary validates it.
struct CloudReceivedEnvelope: Codable, Equatable, Sendable {
    let id: UUID
    let recordName: String
    let metadata: Data
    let systemFields: Data
    let asset: CloudCiphertextReference
}

struct CloudApplicationPlan: Codable, Equatable, Sendable {
    let expectedPreDigest: Data
    let expectedPostDigest: Data
    let postProjection: CloudCatalogProjection
    /// Already merged documents, never credentials to install into another app.
    let documents: [String: CloudRecordBody]
}

struct CloudApplicationReceipt: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case received, applying, applied }
    var phase: Phase
    var plan: CloudApplicationPlan?
}

enum CloudReceiptReplay: Equatable, Sendable {
    case needsApplication(CloudCatalogProjection)
    case completed
    case alreadyApplied
}

struct CloudRestoreIntent: Codable, Equatable, Sendable {
    let id: UUID
    let expectedPreDigest: Data
    let expectedPostDigest: Data
    let postProjection: CloudCatalogProjection
}

struct CloudJournalState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var owner: CloudOwner
    var lamportCounter: UInt64 = 0
    var committedProjection = CloudCatalogProjection(profiles: [])
    var profiles: [String: CloudProfileDocument] = [:]
    var order: CloudOrderDocument?
    var sessions: [String: CloudSessionDocument] = [:]
    var dirtyGenerations: [String: UInt64] = [:]
    /// High-water marks survive acknowledgements, independent of field clocks.
    var recordGenerations: [String: UInt64] = [:]
    var payloadDigests: [String: Data] = [:]
    var systemFields: [String: Data] = [:]
    var receivedEnvelopes: [UUID: CloudReceivedEnvelope] = [:]
    var receipts: [UUID: CloudApplicationReceipt] = [:]
    var lastSuccess: Date?
    var restoreIntent: CloudRestoreIntent?
    var engineState: Data?

    static let orderRecordName = "order.v1"
    static func profileRecordName(_ id: UUID) -> String { "profile." + id.uuidString.lowercased() }

    func sentRevision(for recordName: String) -> CloudSentRevision? {
        guard let generation = dirtyGenerations[recordName], let digest = payloadDigests[recordName] else { return nil }
        return CloudSentRevision(recordName: recordName, generation: generation, payloadDigest: digest)
    }

    mutating func acknowledge(_ revision: CloudSentRevision, systemFields fields: Data? = nil) {
        guard sentRevision(for: revision.recordName) == revision else { return }
        dirtyGenerations.removeValue(forKey: revision.recordName)
        if let fields { systemFields[revision.recordName] = fields }
    }

    /// Used by later session/local publication code in the same transaction as its document edit.
    @discardableResult
    mutating func markDirty(recordName: String, body: CloudRecordBody) throws -> CloudSentRevision {
        try body.validateForWriting()
        let bytes = try CloudJournalCoding.encode(body)
        guard bytes.count <= CloudSyncJournal.maximumAssetBytes else { throw CloudJournalError.tooLarge }
        let (generation, overflow) = (recordGenerations[recordName] ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw CloudSyncModelError.counterOverflow }
        let digest = CloudJournalCoding.digest(bytes)
        recordGenerations[recordName] = generation
        dirtyGenerations[recordName] = generation
        payloadDigests[recordName] = digest
        return CloudSentRevision(recordName: recordName, generation: generation, payloadDigest: digest)
    }

    mutating func reconcile(_ catalog: CloudCatalogRead, deviceID: UUID, now: Date = .now) throws {
        let projection = try catalog.projection()
        guard !receipts.values.contains(where: { $0.phase == .applying }), restoreIntent == nil else {
            throw CloudJournalError.applicationPending
        }
        var next = self
        try next.reconcileCommitted(projection, deviceID: deviceID, now: now)
        self = next
    }

    private mutating func reconcileCommitted(_ projection: CloudCatalogProjection, deviceID: UUID, now: Date) throws {
        let previous = Dictionary(uniqueKeysWithValues: committedProjection.profiles.map { ($0.id, $0) })
        let currentIDs = Set(projection.profiles.map(\.id))
        for row in projection.profiles {
            let key = Self.profileRecordName(row.id)
            let document = profiles[key]
            guard document?.tombstone == nil else { continue }
            guard previous[row.id]?.values != row.values || document == nil else { continue }
            let version = try nextVersion(deviceID: deviceID)
            var fields = document?.fields ?? CloudProfileFields()
            let old = previous[row.id]?.values
            func updated<T>(_ field: CloudField<T>?, _ value: T, _ previous: T?) -> CloudField<T> {
                if let field, previous == value { return field }
                return CloudField(value: value, version: version)
            }
            fields.provider = updated(fields.provider, row.values.provider, old?.provider)
            fields.label = updated(fields.label, row.values.label, old?.label)
            fields.emailLink = updated(fields.emailLink, row.values.emailLink, old.map(\.emailLink))
            fields.password = updated(fields.password, row.values.password, old.map(\.password))
            fields.twoFactorCode = updated(fields.twoFactorCode, row.values.twoFactorCode, old.map(\.twoFactorCode))
            fields.phoneNumber = updated(fields.phoneNumber, row.values.phoneNumber, old.map(\.phoneNumber))
            fields.notes = updated(fields.notes, row.values.notes, old.map(\.notes))
            fields.tags = updated(fields.tags, row.values.tags, old?.tags)
            let replacement = CloudProfileDocument(id: row.id, createdAt: document?.createdAt ?? row.createdAt,
                fields: fields, observations: document?.observations, unknownFields: document?.unknownFields ?? [:])
            profiles[key] = replacement
            try markDirty(recordName: key, body: .profile(replacement))
        }
        for row in committedProjection.profiles where !currentIDs.contains(row.id) {
            let key = Self.profileRecordName(row.id)
            guard let document = profiles[key], document.tombstone == nil else { continue }
            let version = try nextVersion(deviceID: deviceID)
            let deleted = CloudProfileDocument(id: row.id, createdAt: document.createdAt, fields: document.fields,
                observations: document.observations, tombstone: .init(version: version, deletedAt: now), unknownFields: document.unknownFields)
            profiles[key] = deleted
            try markDirty(recordName: key, body: .profile(deleted))
        }
        let ids = projection.profiles.map(\.id).filter { profiles[Self.profileRecordName($0)]?.tombstone == nil }
        if projection.profiles.map(\.id) != committedProjection.profiles.map(\.id), ids != (order?.ids ?? []) {
            let document = CloudOrderDocument(ids: ids, version: try nextVersion(deviceID: deviceID))
            order = document
            try markDirty(recordName: Self.orderRecordName, body: .order(document))
        }
        committedProjection = projection
    }

    mutating func beginApplying(_ id: UUID, postProjection: CloudCatalogProjection, documents: [String: CloudRecordBody]) throws {
        guard receivedEnvelopes[id] != nil, receipts[id]?.phase == .received,
              !receipts.values.contains(where: { $0.phase == .applying }), restoreIntent == nil else {
            throw CloudJournalError.invalidTransition
        }
        let plan = CloudApplicationPlan(expectedPreDigest: try committedProjection.digest(),
            expectedPostDigest: try postProjection.digest(), postProjection: postProjection, documents: documents)
        for (name, body) in documents { try Self.validateBody(body, name: name) }
        receipts[id] = CloudApplicationReceipt(phase: .applying, plan: plan)
    }

    /// Caller first persists `applying`, commits the catalog, then supplies a fresh trusted read.
    /// On restart a preimage needs application; a postimage needs only journal finalization.
    mutating func replay(_ id: UUID, catalog: CloudCatalogRead) throws -> CloudReceiptReplay {
        guard let receipt = receipts[id] else { throw CloudJournalError.invalidTransition }
        if receipt.phase == .applied { return .alreadyApplied }
        guard receipt.phase == .applying, let plan = receipt.plan else { throw CloudJournalError.invalidTransition }
        let digest = try catalog.projection().digest()
        if digest == plan.expectedPostDigest {
            var next = self
            for (name, body) in plan.documents {
                try Self.validateBody(body, name: name)
                switch body {
                case .profile(let document): next.profiles[name] = document
                case .order(let document): next.order = document
                case .session(let document): next.sessions[name] = document
                }
                if next.dirtyGenerations[name] != nil,
                   next.payloadDigests[name] != CloudJournalCoding.digest(try CloudJournalCoding.encode(body)) {
                    try next.markDirty(recordName: name, body: body)
                }
            }
            next.lamportCounter = max(next.lamportCounter, next.maximumObservedCounter)
            next.committedProjection = plan.postProjection
            next.receipts[id]?.phase = .applied
            if let envelope = next.receivedEnvelopes[id] { next.systemFields[envelope.recordName] = envelope.systemFields }
            self = next
            return .completed
        }
        if digest == plan.expectedPreDigest { return .needsApplication(plan.postProjection) }
        throw CloudJournalError.catalogDiverged
    }

    private var maximumObservedCounter: UInt64 {
        var greatest = order?.version.counter ?? 0
        for profile in profiles.values {
            for version in profile.fields.versions + profile.unknownFields.values.map(\.version) {
                greatest = max(greatest, version.counter)
            }
            greatest = max(greatest, profile.tombstone?.version.counter ?? 0)
        }
        return greatest
    }

    private mutating func nextVersion(deviceID: UUID) throws -> CloudVersion {
        let version = try CloudVersion.next(after: max(lamportCounter, maximumObservedCounter), observing: [], deviceID: deviceID)
        lamportCounter = version.counter
        return version
    }

    func validate(expectedOwner: CloudOwner) throws {
        guard schemaVersion == 1 else { throw CloudJournalError.unsupportedSchema(schemaVersion) }
        guard owner == expectedOwner else { throw CloudJournalError.ownerMismatch }
        guard !owner.container.isEmpty, !owner.userRecordName.isEmpty else { throw CloudJournalError.invalidState }
        try committedProjection.validate()
        guard lamportCounter >= maximumObservedCounter,
              lastSuccess?.timeIntervalSince1970.isFinite ?? true,
              receipts.values.filter({ $0.phase == .applying }).count <= 1 else { throw CloudJournalError.invalidState }
        for (name, document) in profiles { try Self.validateBody(.profile(document), name: name) }
        if let order { try Self.validateBody(.order(order), name: Self.orderRecordName) }
        for (name, document) in sessions { try Self.validateBody(.session(document), name: name) }
        guard Set(recordGenerations.keys) == Set(payloadDigests.keys) else { throw CloudJournalError.invalidState }
        for (name, generation) in recordGenerations {
            guard generation > 0, payloadDigests[name]?.count == 32 else { throw CloudJournalError.invalidState }
        }
        for (name, generation) in dirtyGenerations {
            guard generation > 0, generation == recordGenerations[name], let body = body(for: name),
                  payloadDigests[name] == CloudJournalCoding.digest(try CloudJournalCoding.encode(body)) else {
                throw CloudJournalError.invalidState
            }
        }
        for (id, envelope) in receivedEnvelopes {
            guard id == envelope.id, receipts[id] != nil, !envelope.recordName.isEmpty,
                  envelope.asset.fileName == id.uuidString.lowercased() + ".asset",
                  (1...CloudSyncJournal.maximumAssetBytes).contains(envelope.asset.byteCount),
                  envelope.asset.digest.count == 32 else { throw CloudJournalError.invalidState }
        }
        for (id, receipt) in receipts {
            if receipt.phase != .applied, receivedEnvelopes[id] == nil { throw CloudJournalError.invalidState }
            if receipt.phase == .received {
                guard receipt.plan == nil else { throw CloudJournalError.invalidState }
            } else {
                guard let plan = receipt.plan, plan.expectedPreDigest.count == 32,
                      plan.expectedPostDigest == (try plan.postProjection.digest()) else { throw CloudJournalError.invalidState }
                for (name, body) in plan.documents { try Self.validateBody(body, name: name) }
                if receipt.phase == .applying, plan.expectedPreDigest != (try committedProjection.digest()) {
                    throw CloudJournalError.invalidState
                }
            }
        }
        if let intent = restoreIntent {
            guard intent.expectedPreDigest.count == 32,
                  intent.expectedPostDigest == (try intent.postProjection.digest()) else { throw CloudJournalError.invalidState }
        }
    }

    private func body(for name: String) -> CloudRecordBody? {
        if let profile = profiles[name] { return .profile(profile) }
        if name == Self.orderRecordName, let order { return .order(order) }
        if let session = sessions[name] { return .session(session) }
        return nil
    }

    private static func validateBody(_ body: CloudRecordBody, name: String) throws {
        try body.validateForWriting()
        switch body {
        case .profile(let profile):
            guard name == profileRecordName(profile.id), profile.createdAt.timeIntervalSince1970.isFinite,
                  profile.tombstone?.deletedAt.timeIntervalSince1970.isFinite ?? true else { throw CloudJournalError.invalidState }
        case .order(let order):
            guard name == orderRecordName, Set(order.ids).count == order.ids.count else { throw CloudJournalError.invalidState }
        case .session(let session):
            guard !name.isEmpty, name != orderRecordName, !name.hasPrefix("profile."),
                  session.capturedAt.timeIntervalSince1970.isFinite else { throw CloudJournalError.invalidState }
        }
    }
}
