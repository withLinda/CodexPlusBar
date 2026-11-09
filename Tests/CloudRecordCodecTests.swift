import CloudKit
import Foundation
import Testing
@testable import CodexPlusBar

struct CloudRecordCodecTests {
    @Test func authenticatedMalformedDocumentIsAnItemErrorBeforeJournalMutation() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let codec = CloudRecordCodec(assets: .init(root: f.root))
        let key = try CloudCryptoFixture.key(), id = UUID()
        let duplicateOrder = CloudRecordBody.order(.init(ids: [id, id], version: .init(counter: 1, deviceID: UUID())))
        let routing = CloudRecordRouting(schemaVersion: 1, kind: "order", keyID: key.id, profileID: nil)
        let encrypted = try CloudPayloadCipher.seal(CloudJournalCoding.encode(duplicateOrder), key: key,
            context: .init(owner: CloudCryptoFixture.owner, recordName: "order.v1", kind: "order", schema: 1, keyID: key.id))
        let envelope = CloudRecordEnvelope(id: UUID(), recordName: "order.v1", routing: routing, ciphertext: encrypted, systemFields: Data())
        #expect(throws: CloudRecordCodecError.invalidRecord) { try codec.decode(envelope, owner: CloudCryptoFixture.owner, key: key) }
        #expect(throws: CloudRecordCodecError.invalidRecord) { try codec.encode(duplicateOrder, owner: CloudCryptoFixture.owner, key: key) }
    }

    @Test func encryptedRecordsUseStableNamesAndOnlyRoutingFields() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let codec = CloudRecordCodec(assets: CloudAssetStore(root: f.root))
        let key = try CloudCryptoFixture.key()
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let device = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let bodies: [CloudRecordBody] = [
            .profile(.init(id: id, createdAt: .distantPast, fields: .init(label: .init(value: "synthetic secret", version: .init(counter: 1, deviceID: device))))),
            .order(.init(ids: [id], version: .init(counter: 2, deviceID: device))),
            .session(.init(profileID: id, sourceDeviceID: device, sourceName: "synthetic Mac", kind: .desktop, revision: 7, capturedAt: .distantPast, payload: Data([1, 2, 3])))
        ]
        let names = ["profile.11111111-1111-1111-1111-111111111111", "order.v1",
                     "session.11111111-1111-1111-1111-111111111111.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.desktop.7"]
        for (body, name) in zip(bodies, names) {
            #expect(CloudRecordCodec.recordName(for: body) == name)
            let encoded = try codec.encode(body, owner: CloudCryptoFixture.owner, key: key)
            #expect(encoded.record.recordID.recordName == name)
            #expect(encoded.record.recordID.zoneID.zoneName == "AccountSyncV1")
            #expect(encoded.record.recordType == "CPBEncryptedRecordV1")
            let expected: Set<String> = name == "order.v1" ? ["schemaVersion", "kind", "keyID", "payload"] : ["schemaVersion", "kind", "keyID", "profileID", "payload"]
            #expect(Set(encoded.record.allKeys()) == expected)
            let envelope = try codec.envelope(from: encoded.record)
            #expect(try codec.decode(envelope, owner: CloudCryptoFixture.owner, key: key) == body)
            #expect(!envelope.ciphertext.contains(Data("synthetic secret".utf8)))
            #expect(throws: CloudAssetError.inUse) { try codec.assets.remove(encoded.assetURL) }
            encoded.lease.release()
            try codec.assets.remove(encoded.assetURL)
        }
    }

    @Test func authenticationAndDecryptedRoutingRejectSubstitution() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let codec = CloudRecordCodec(assets: .init(root: f.root))
        let key = try CloudCryptoFixture.key()
        let body = CloudRecordBody.profile(.init(id: UUID(), createdAt: .distantPast))
        let encoded = try codec.encode(body, owner: CloudCryptoFixture.owner, key: key)
        encoded.record["profileID"] = UUID().uuidString.lowercased() as CKRecordValue
        let envelope = try codec.envelope(from: encoded.record)
        #expect(throws: CloudRecordCodecError.routingMismatch) { try codec.decode(envelope, owner: CloudCryptoFixture.owner, key: key) }
        encoded.record["kind"] = "session" as CKRecordValue
        let tampered = try codec.envelope(from: encoded.record)
        #expect(throws: (any Error).self) { try codec.decode(tampered, owner: CloudCryptoFixture.owner, key: key) }
    }

    @Test func futureSchemaIsRetainedOpaqueAndSystemFieldsAreReused() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let codec = CloudRecordCodec(assets: .init(root: f.root))
        let key = try CloudCryptoFixture.key()
        let body = CloudRecordBody.profile(.init(id: UUID(), createdAt: .distantPast))
        let encoded = try codec.encode(body, owner: CloudCryptoFixture.owner, key: key)
        let archived = try CloudRecordCodec.systemFields(of: encoded.record)
        let replacement = try codec.encode(body, owner: CloudCryptoFixture.owner, key: key, systemFields: archived)
        #expect(try CloudRecordCodec.systemFields(of: replacement.record) == archived)
        encoded.record["schemaVersion"] = Int64(2) as CKRecordValue
        let future = try codec.envelope(from: encoded.record)
        #expect(future.routing.schemaVersion == 2)
        #expect(throws: CloudRecordCodecError.unsupportedSchema(2)) { try codec.decode(future, owner: CloudCryptoFixture.owner, key: key) }
        #expect(throws: (any Error).self) { try codec.encode(.profile(.init(id: UUID(), createdAt: .distantPast)), owner: CloudCryptoFixture.owner, key: key, systemFields: archived) }
    }

    @Test func invalidTypesZonesAndOversizedAssetsAreRejectedBeforeDecoding() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let codec = CloudRecordCodec(assets: .init(root: f.root))
        let key = try CloudCryptoFixture.key()
        let encoded = try codec.encode(.profile(.init(id: UUID(), createdAt: .distantPast)), owner: CloudCryptoFixture.owner, key: key)
        encoded.record["schemaVersion"] = "1" as CKRecordValue
        #expect(throws: CloudRecordCodecError.invalidRecord) { try codec.envelope(from: encoded.record) }
        let alien = CKRecord(recordType: "CPBEncryptedRecordV1", recordID: .init(recordName: "order.v1", zoneID: .init(zoneName: "Other")))
        #expect(throws: CloudRecordCodecError.invalidRecord) { try codec.envelope(from: alien) }
        encoded.record["schemaVersion"] = Int64(1) as CKRecordValue
        let huge = f.base.appendingPathComponent("huge")
        _ = FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(CloudPayloadCipher.maximumAssetBytes + 1)); try handle.close()
        encoded.record["payload"] = CKAsset(fileURL: huge)
        #expect(throws: CloudJournalError.tooLarge) { try codec.envelope(from: encoded.record) }
    }
}
