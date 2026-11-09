import Foundation
@testable import CodexPlusBar

enum CloudSyncTestSupport {
    static let profileID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let deviceA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let deviceB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let deviceC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let createdAt = Date(timeIntervalSince1970: 1_000)

    static func version(_ counter: UInt64, _ device: UUID = deviceA) -> CloudVersion {
        CloudVersion(counter: counter, deviceID: device)
    }

    static func document(
        id: UUID = profileID,
        createdAt: Date = createdAt,
        fields: CloudProfileFields = CloudProfileFields(),
        observations: CloudProfileObservations? = nil,
        tombstone: CloudTombstone? = nil,
        unknownFields: [String: CloudField<Data>] = [:],
        schemaVersion: Int = 1
    ) -> CloudProfileDocument {
        CloudProfileDocument(
            schemaVersion: schemaVersion, id: id, createdAt: createdAt,
            fields: fields, observations: observations, tombstone: tombstone,
            unknownFields: unknownFields
        )
    }

    static func session(profileID: UUID = profileID, revision: UInt64 = 1) -> CloudSessionDocument {
        CloudSessionDocument(
            profileID: profileID, sourceDeviceID: deviceA, sourceName: "Synthetic Mac",
            kind: .browser, revision: revision, capturedAt: createdAt,
            payload: Data(UUID().uuidString.utf8)
        )
    }

    /// Reproducible replicas use distinct source UUIDs and complete, internally consistent versions.
    static func replica(seed: Int, device: UUID) -> CloudProfileDocument {
        let counter = UInt64(seed % 7 + 1)
        let stamp = version(counter, device)
        var fields = CloudProfileFields()
        fields.provider = CloudField(value: seed.isMultiple(of: 2) ? "codex" : "inactive-provider", version: stamp)
        fields.label = CloudField(value: "Label \(seed)", version: stamp)
        if seed.isMultiple(of: 2) {
            fields.notes = CloudField(value: "Notes \(seed)", version: stamp)
            fields.emailLink = CloudField(value: nil, version: stamp)
        }
        if seed.isMultiple(of: 3) {
            fields.password = CloudField(value: nil, version: stamp)
            fields.twoFactorCode = CloudField(value: nil, version: stamp)
            fields.phoneNumber = CloudField(value: "\(seed)", version: stamp)
        }
        fields.tags = CloudField(value: seed.isMultiple(of: 2) ? ["active"] : ["pending"], version: stamp)
        let capturedAt = Date(timeIntervalSince1970: Double(seed % 5))
        let observations = CloudProfileObservations(
            expiresAt: CloudObservation(value: capturedAt, capturedAt: capturedAt, deviceID: device),
            detectedNote: CloudObservation(value: "Detected \(seed)", capturedAt: capturedAt, deviceID: device)
        )
        return document(
            createdAt: Date(timeIntervalSince1970: Double(seed)), fields: fields,
            observations: observations,
            tombstone: seed.isMultiple(of: 11) ? CloudTombstone(version: stamp, deletedAt: capturedAt) : nil,
            unknownFields: ["extension": CloudField(value: Data([UInt8(seed)]), version: stamp)]
        )
    }
}
