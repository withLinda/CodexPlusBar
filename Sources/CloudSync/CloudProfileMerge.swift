import Foundation

enum CloudProfileMerge {
    static func merge(_ lhs: CloudProfileDocument, _ rhs: CloudProfileDocument) throws -> CloudProfileDocument {
        try lhs.validateForWriting()
        try rhs.validateForWriting()
        guard lhs.id == rhs.id else { throw CloudSyncModelError.profileIdentityMismatch }

        let fields = try CloudProfileFields(
            provider: mergeField(lhs.fields.provider, rhs.fields.provider),
            label: mergeField(lhs.fields.label, rhs.fields.label),
            emailLink: mergeField(lhs.fields.emailLink, rhs.fields.emailLink),
            password: mergeField(lhs.fields.password, rhs.fields.password),
            twoFactorCode: mergeField(lhs.fields.twoFactorCode, rhs.fields.twoFactorCode),
            phoneNumber: mergeField(lhs.fields.phoneNumber, rhs.fields.phoneNumber),
            notes: mergeField(lhs.fields.notes, rhs.fields.notes),
            tags: mergeField(lhs.fields.tags, rhs.fields.tags)
        )
        var unknownFields = lhs.unknownFields
        for (key, field) in rhs.unknownFields {
            unknownFields[key] = try mergeField(unknownFields[key], field)
        }
        return try CloudProfileDocument(
            id: lhs.id,
            createdAt: min(lhs.createdAt, rhs.createdAt),
            fields: fields,
            observations: mergeObservations(lhs.observations, rhs.observations),
            tombstone: mergeTombstone(lhs.tombstone, rhs.tombstone),
            unknownFields: unknownFields
        )
    }

    /// Applies an order without changing its version or publishing a normalization as a local edit.
    static func orderedIDs(_ order: CloudOrderDocument?, profiles: [CloudProfileDocument]) -> [UUID] {
        let deletedIDs = Set(profiles.filter { $0.tombstone != nil }.map(\.id))
        var creationDates: [UUID: Date] = [:]
        for profile in profiles where !deletedIDs.contains(profile.id) {
            creationDates[profile.id] = min(creationDates[profile.id] ?? profile.createdAt, profile.createdAt)
        }
        var seen = Set<UUID>()
        var result: [UUID] = []
        // Unknown schemas are retained elsewhere; do not interpret their ordering semantics.
        if let order, order.schemaVersion == CloudSyncSchema.currentVersion {
            for id in order.ids where creationDates[id] != nil && seen.insert(id).inserted {
                result.append(id)
            }
        }
        let extras = creationDates.filter { !seen.contains($0.key) }.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.uuidString < rhs.key.uuidString
        }
        result.append(contentsOf: extras.map(\.key))
        return result
    }

    /// Only the profile/schema/deletion gate. A true result does not verify credentials or generation.
    static func isSessionEligible(_ session: CloudSessionDocument, for profile: CloudProfileDocument?) -> Bool {
        guard let profile,
              profile.schemaVersion == CloudSyncSchema.currentVersion,
              session.schemaVersion == CloudSyncSchema.currentVersion,
              session.profileID == profile.id else { return false }
        return profile.tombstone == nil
    }

    private static func mergeField<Value>(_ lhs: CloudField<Value>?, _ rhs: CloudField<Value>?) throws -> CloudField<Value>? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs.version != rhs.version { return lhs.version > rhs.version ? lhs : rhs }
        guard lhs == rhs else { throw CloudSyncModelError.conflictingVersion }
        return lhs
    }

    private static func mergeObservations(
        _ lhs: CloudProfileObservations?, _ rhs: CloudProfileObservations?
    ) throws -> CloudProfileObservations? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return try CloudProfileObservations(
            expiresAt: mergeObservation(lhs.expiresAt, rhs.expiresAt),
            detectedNote: mergeObservation(lhs.detectedNote, rhs.detectedNote)
        )
    }

    private static func mergeObservation<Value>(
        _ lhs: CloudObservation<Value>?, _ rhs: CloudObservation<Value>?
    ) throws -> CloudObservation<Value>? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt > rhs.capturedAt ? lhs : rhs }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID.uuidString > rhs.deviceID.uuidString ? lhs : rhs }
        guard lhs == rhs else { throw CloudSyncModelError.conflictingVersion }
        return lhs
    }

    private static func mergeTombstone(_ lhs: CloudTombstone?, _ rhs: CloudTombstone?) -> CloudTombstone? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs.version != rhs.version { return lhs.version > rhs.version ? lhs : rhs }
        return lhs.deletedAt <= rhs.deletedAt ? lhs : rhs
    }
}
