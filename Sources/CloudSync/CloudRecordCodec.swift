import CloudKit
import Foundation

enum CloudRecordCodecError: Error, Equatable, Sendable {
    case invalidRecord, routingMismatch, unsupportedSchema(Int)
}

struct CloudRecordRouting: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let keyID: UUID
    let profileID: UUID?
}

struct CloudRecordEnvelope: Sendable {
    let id: UUID
    let recordName: String
    let routing: CloudRecordRouting
    let ciphertext: Data
    let systemFields: Data
}

struct CloudEncodedRecord: Sendable {
    let record: CKRecord
    let assetURL: URL
    let lease: CloudAssetLease
}

struct CloudRecordCodec: Sendable {
    let assets: CloudAssetStore
    static let recordType = "CPBEncryptedRecordV1"
    static let zoneID = CKRecordZone.ID(zoneName: CloudPayloadContext.zoneName)
    private enum Field {
        static let schema = "schemaVersion", kind = "kind", key = "keyID", profile = "profileID", payload = "payload"
    }

    static func recordName(for body: CloudRecordBody) -> String {
        switch body {
        case .profile(let profile): CloudJournalState.profileRecordName(profile.id)
        case .order: CloudJournalState.orderRecordName
        case .session(let session):
            "session.\(session.profileID.uuidString.lowercased()).\(session.sourceDeviceID.uuidString.lowercased()).\(session.kind.rawValue).\(session.revision)"
        }
    }

    static func recordID(_ name: String) -> CKRecord.ID { .init(recordName: name, zoneID: zoneID) }

    static func systemFields(of record: CKRecord) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        if let error = coder.error { throw error }
        guard coder.encodedData.count <= 1_048_576 else { throw CloudRecordCodecError.invalidRecord }
        return coder.encodedData
    }

    private static func restoredRecord(_ bytes: Data) throws -> CKRecord {
        guard bytes.count <= 1_048_576 else { throw CloudRecordCodecError.invalidRecord }
        let coder = try NSKeyedUnarchiver(forReadingFrom: bytes)
        coder.requiresSecureCoding = true
        coder.decodingFailurePolicy = .setErrorAndReturn
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), coder.error == nil else { throw CloudRecordCodecError.invalidRecord }
        return record
    }

    func encode(_ body: CloudRecordBody, owner: CloudOwner, key: CloudEncryptionKey, systemFields: Data? = nil) throws -> CloudEncodedRecord {
        try Self.validate(body)
        let name = Self.recordName(for: body)
        let routing = Self.routing(for: body, keyID: key.id)
        let bytes = try CloudJournalCoding.encode(body)
        let encrypted = try CloudPayloadCipher.seal(bytes, key: key, context: context(owner, name, routing))
        let record: CKRecord
        if let systemFields, !systemFields.isEmpty { record = try Self.restoredRecord(systemFields) }
        else { record = CKRecord(recordType: Self.recordType, recordID: Self.recordID(name)) }
        guard record.recordID == Self.recordID(name), record.recordType == Self.recordType else { throw CloudRecordCodecError.routingMismatch }
        let url = try assets.stage(encrypted)
        let lease = try assets.retainForSend(url)
        record[Field.schema] = Int64(routing.schemaVersion) as CKRecordValue
        record[Field.kind] = routing.kind as CKRecordValue
        record[Field.key] = key.id.uuidString.lowercased() as CKRecordValue
        record[Field.profile] = routing.profileID?.uuidString.lowercased() as CKRecordValue?
        record[Field.payload] = CKAsset(fileURL: url)
        return CloudEncodedRecord(record: record, assetURL: url, lease: lease)
    }

    func envelope(from record: CKRecord) throws -> CloudRecordEnvelope {
        guard record.recordType == Self.recordType, record.recordID.zoneID == Self.zoneID,
              !record.recordID.recordName.isEmpty, record.recordID.recordName.utf8.count <= 255,
              let schema = record[Field.schema] as? NSNumber,
              ["s", "i", "l", "q"].contains(String(cString: schema.objCType)), schema.int64Value > 0,
              let kind = record[Field.kind] as? String, !kind.isEmpty, kind.utf8.count <= 128,
              let keyText = record[Field.key] as? String, let keyID = UUID(uuidString: keyText),
              keyText == keyID.uuidString.lowercased(),
              let asset = record[Field.payload] as? CKAsset, let url = asset.fileURL else { throw CloudRecordCodecError.invalidRecord }
        let profileID: UUID?
        if let value = record[Field.profile] {
            guard let text = value as? String, let id = UUID(uuidString: text), text == id.uuidString.lowercased() else { throw CloudRecordCodecError.invalidRecord }
            profileID = id
        } else { profileID = nil }
        let routing = CloudRecordRouting(schemaVersion: schema.intValue, kind: kind, keyID: keyID, profileID: profileID)
        let ciphertext = try assets.encryptedBytes(from: url)
        guard !ciphertext.isEmpty else { throw CloudRecordCodecError.invalidRecord }
        let fields = try Self.systemFields(of: record)
        var identity = Data(record.recordID.recordName.utf8)
        identity.append(try CloudJournalCoding.encode(routing))
        identity.append(CloudJournalCoding.digest(ciphertext)); identity.append(CloudJournalCoding.digest(fields))
        let hash = Array(CloudJournalCoding.digest(identity).prefix(16))
        let id = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        return CloudRecordEnvelope(id: id, recordName: record.recordID.recordName, routing: routing, ciphertext: ciphertext, systemFields: fields)
    }

    func decode(_ envelope: CloudRecordEnvelope, owner: CloudOwner, key: CloudEncryptionKey) throws -> CloudRecordBody {
        guard envelope.routing.schemaVersion == 1 else { throw CloudRecordCodecError.unsupportedSchema(envelope.routing.schemaVersion) }
        let plaintext = try CloudPayloadCipher.open(envelope.ciphertext, key: key, context: context(owner, envelope.recordName, envelope.routing))
        let body = try JSONDecoder().decode(CloudRecordBody.self, from: plaintext)
        try Self.validate(body)
        guard Self.routing(for: body, keyID: key.id) == envelope.routing,
              Self.recordName(for: body) == envelope.recordName else { throw CloudRecordCodecError.routingMismatch }
        return body
    }

    private static func routing(for body: CloudRecordBody, keyID: UUID) -> CloudRecordRouting {
        switch body {
        case .profile(let document): .init(schemaVersion: document.schemaVersion, kind: "profile", keyID: keyID, profileID: document.id)
        case .order(let document): .init(schemaVersion: document.schemaVersion, kind: "order", keyID: keyID, profileID: nil)
        case .session(let document): .init(schemaVersion: document.schemaVersion, kind: "session", keyID: keyID, profileID: document.profileID)
        }
    }

    private static func validate(_ body: CloudRecordBody) throws {
        try body.validateForWriting()
        let valid: Bool
        switch body {
        case .profile(let document):
            valid = document.createdAt.timeIntervalSince1970.isFinite &&
                (document.tombstone?.deletedAt.timeIntervalSince1970.isFinite ?? true)
        case .order(let document): valid = Set(document.ids).count == document.ids.count
        case .session(let document): valid = document.capturedAt.timeIntervalSince1970.isFinite
        }
        guard valid else { throw CloudRecordCodecError.invalidRecord }
    }

    private func context(_ owner: CloudOwner, _ name: String, _ routing: CloudRecordRouting) -> CloudPayloadContext {
        .init(owner: owner, recordName: name, kind: routing.kind, schema: routing.schemaVersion, keyID: routing.keyID)
    }
}
