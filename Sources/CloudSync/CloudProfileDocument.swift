import Foundation

/// Only the eight user-editable fields. Raw IDs retain inactive providers and unknown tags.
struct CloudProfileValues: Codable, Equatable, Sendable {
    var provider: String
    var label: String
    var emailLink: String? = nil
    var password: String? = nil
    var twoFactorCode: String? = nil
    var phoneNumber: String? = nil
    var notes: String? = nil
    var tags: [String] = []
}

struct CloudProfileFields: Codable, Equatable, Sendable {
    var provider: CloudField<String>? = nil
    var label: CloudField<String>? = nil
    var emailLink: CloudField<String?>? = nil
    var password: CloudField<String?>? = nil
    var twoFactorCode: CloudField<String?>? = nil
    var phoneNumber: CloudField<String?>? = nil
    var notes: CloudField<String?>? = nil
    var tags: CloudField<[String]>? = nil

    var versions: [CloudVersion] {
        [provider?.version, label?.version, emailLink?.version, password?.version,
         twoFactorCode?.version, phoneNumber?.version, notes?.version, tags?.version].compactMap { $0 }
    }
}

extension CloudProfileFields {
    /// For the first committed projection. Later edits must version only changed fields.
    init(values: CloudProfileValues, version: CloudVersion) {
        self.init(
            provider: CloudField(value: values.provider, version: version),
            label: CloudField(value: values.label, version: version),
            emailLink: CloudField(value: values.emailLink, version: version),
            password: CloudField(value: values.password, version: version),
            twoFactorCode: CloudField(value: values.twoFactorCode, version: version),
            phoneNumber: CloudField(value: values.phoneNumber, version: version),
            notes: CloudField(value: values.notes, version: version),
            tags: CloudField(value: values.tags, version: version)
        )
    }
}

struct CloudProfileObservations: Codable, Equatable, Sendable {
    var expiresAt: CloudObservation<Date?>? = nil
    var detectedNote: CloudObservation<String?>? = nil
}

struct CloudProfileDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let fields: CloudProfileFields
    let observations: CloudProfileObservations?
    let tombstone: CloudTombstone?
    /// Extension fields are versioned opaque bytes, never decoded as a guessed current field type.
    /// Writers introducing fields must retain this extension map, including fields they do not know.
    let unknownFields: [String: CloudField<Data>]

    init(
        schemaVersion: Int = CloudSyncSchema.currentVersion,
        id: UUID,
        createdAt: Date,
        fields: CloudProfileFields = CloudProfileFields(),
        observations: CloudProfileObservations? = nil,
        tombstone: CloudTombstone? = nil,
        unknownFields: [String: CloudField<Data>] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.fields = fields
        self.observations = observations
        self.tombstone = tombstone
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, fields, observations, tombstone, unknownFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fields = try container.decodeIfPresent(CloudProfileFields.self, forKey: .fields) ?? CloudProfileFields()
        observations = try container.decodeIfPresent(CloudProfileObservations.self, forKey: .observations)
        tombstone = try container.decodeIfPresent(CloudTombstone.self, forKey: .tombstone)
        unknownFields = try container.decodeIfPresent([String: CloudField<Data>].self, forKey: .unknownFields) ?? [:]
    }

    func validateForWriting() throws {
        try CloudSyncSchema.validateForWriting(schemaVersion)
    }

    /// Includes retained extension clocks so local writes cannot lag an observed unknown field.
    func nextVersion(after localCounter: UInt64, deviceID: UUID) throws -> CloudVersion {
        try validateForWriting()
        var versions = fields.versions + unknownFields.values.map(\.version)
        if let tombstone { versions.append(tombstone.version) }
        return try CloudVersion.next(after: localCounter, observing: versions, deviceID: deviceID)
    }
}
