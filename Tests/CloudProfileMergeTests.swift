import Foundation
import Testing
@testable import CodexPlusBar

struct CloudProfileMergeTests {
    private typealias Fixture = CloudSyncTestSupport

    @Test
    func mergeIsCommutativeIdempotentAndAssociativeAcrossGeneratedReplicas() throws {
        for seed in 0..<64 {
            let a = Fixture.replica(seed: seed, device: Fixture.deviceA)
            let b = Fixture.replica(seed: seed + 1, device: Fixture.deviceB)
            let c = Fixture.replica(seed: seed + 2, device: Fixture.deviceC)
            let ab = try CloudProfileMerge.merge(a, b)
            let ba = try CloudProfileMerge.merge(b, a)
            let aa = try CloudProfileMerge.merge(a, a)
            let left = try CloudProfileMerge.merge(ab, c)
            let right = try CloudProfileMerge.merge(a, CloudProfileMerge.merge(b, c))
            #expect(ab == ba)
            #expect(aa == a)
            #expect(left == right)
        }
    }

    @Test
    func differentFieldEditsBothSurvive() throws {
        var local = CloudProfileFields()
        local.label = CloudField(value: "A", version: Fixture.version(2))
        var remote = CloudProfileFields()
        remote.notes = CloudField(value: "B", version: Fixture.version(3, Fixture.deviceB))
        let result = try CloudProfileMerge.merge(Fixture.document(fields: local), Fixture.document(fields: remote))
        #expect(result.fields.label?.value == "A")
        #expect(result.fields.notes?.value == "B")
    }

    @Test
    func equalCountersChooseLexicallyGreaterCanonicalDeviceUUID() throws {
        let lower = UUID(uuidString: "99999999-ffff-ffff-ffff-ffffffffffff")!
        let higher = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000000")!
        var a = CloudProfileFields()
        a.label = CloudField(value: "A", version: Fixture.version(8, lower))
        var b = CloudProfileFields()
        b.label = CloudField(value: "B", version: Fixture.version(8, higher))
        let result = try CloudProfileMerge.merge(Fixture.document(fields: a), Fixture.document(fields: b))
        #expect(result.fields.label?.value == "B")
        #expect(Fixture.version(9, lower) > Fixture.version(8, higher))
    }

    @Test
    func explicitNilClearsButMissingFieldPreservesIncludingAfterCoding() throws {
        var original = CloudProfileFields()
        original.notes = CloudField(value: "Keep until cleared", version: Fixture.version(1))
        var clear = CloudProfileFields()
        clear.notes = CloudField(value: nil, version: Fixture.version(2))
        let decodedClear = try roundTrip(Fixture.document(fields: clear))
        let absent = try roundTrip(Fixture.document())
        #expect(decodedClear.fields.notes != nil)
        #expect(decodedClear.fields.notes?.value == nil)
        #expect(absent.fields.notes == nil)
        let kept = try CloudProfileMerge.merge(Fixture.document(fields: original), absent)
        let cleared = try CloudProfileMerge.merge(kept, decodedClear)
        #expect(kept.fields.notes?.value == "Keep until cleared")
        #expect(cleared.fields.notes != nil)
        #expect(cleared.fields.notes?.value == nil)
    }

    @Test
    func tagsAreOneFieldRatherThanAUnion() throws {
        var a = CloudProfileFields()
        a.tags = CloudField(value: ["active", "pending"], version: Fixture.version(1))
        var b = CloudProfileFields()
        b.tags = CloudField(value: ["need_action", "future-tag"], version: Fixture.version(2))
        let result = try CloudProfileMerge.merge(Fixture.document(fields: a), Fixture.document(fields: b))
        #expect(result.fields.tags?.value == ["need_action", "future-tag"])
    }

    @Test
    func reversedWallClocksDoNotDecideUserEditsAndCreationUsesEarlierDate() throws {
        var a = CloudProfileFields()
        a.label = CloudField(value: "Higher counter", version: Fixture.version(9))
        var b = CloudProfileFields()
        b.label = CloudField(value: "Later clock", version: Fixture.version(2, Fixture.deviceB))
        let earlier = Date(timeIntervalSince1970: -1_000)
        let later = Date(timeIntervalSince1970: 9_000)
        let result = try CloudProfileMerge.merge(
            Fixture.document(createdAt: earlier, fields: a),
            Fixture.document(createdAt: later, fields: b)
        )
        #expect(result.fields.label?.value == "Higher counter")
        #expect(result.createdAt == earlier)
        let reversed = try CloudProfileMerge.merge(
            Fixture.document(createdAt: later, fields: a),
            Fixture.document(createdAt: earlier, fields: b)
        )
        #expect(reversed == result)
    }

    @Test
    func tombstoneDominatesEvenHigherCounterEditsAndEverySessionRevision() throws {
        let tombstone = CloudTombstone(version: Fixture.version(1), deletedAt: Fixture.createdAt)
        let deleted = Fixture.document(tombstone: tombstone)
        var edit = CloudProfileFields()
        edit.label = CloudField(value: "Offline edit", version: Fixture.version(999, Fixture.deviceB))
        let result = try CloudProfileMerge.merge(deleted, Fixture.document(fields: edit))
        #expect(result.tombstone == tombstone)
        #expect(CloudProfileMerge.orderedIDs(nil, profiles: [result]).isEmpty)
        #expect(!CloudProfileMerge.isSessionEligible(Fixture.session(), for: result))
        #expect(!CloudProfileMerge.isSessionEligible(Fixture.session(revision: .max), for: result))
        #expect(CloudProfileMerge.isSessionEligible(Fixture.session(), for: Fixture.document()))
        #expect(!CloudProfileMerge.isSessionEligible(Fixture.session(profileID: UUID()), for: Fixture.document()))
        #expect(!CloudProfileMerge.isSessionEligible(Fixture.session(), for: nil))
    }

    @Test
    func tombstoneTieUsesVersionThenEarlierDeletionDate() throws {
        let first = CloudTombstone(version: Fixture.version(3), deletedAt: Fixture.createdAt)
        let second = CloudTombstone(version: Fixture.version(3), deletedAt: Fixture.createdAt.addingTimeInterval(10))
        let a = Fixture.document(tombstone: first)
        let b = Fixture.document(tombstone: second)
        let result = try CloudProfileMerge.merge(a, b)
        #expect(result.tombstone == first)
        #expect(try CloudProfileMerge.merge(b, a) == result)
    }

    @Test
    func orderFiltersMissingDeletedAndRepeatedIDsAndAppendsByCreationThenUUID() {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let newestID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let deletedID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        let profiles = [
            Fixture.document(id: newestID, createdAt: Fixture.createdAt.addingTimeInterval(1)),
            Fixture.document(id: secondID), Fixture.document(id: firstID), Fixture.document(),
            Fixture.document(id: deletedID, tombstone: CloudTombstone(version: Fixture.version(1), deletedAt: Fixture.createdAt)),
        ]
        let order = CloudOrderDocument(ids: [secondID, UUID(), deletedID, secondID, Fixture.profileID], version: Fixture.version(1))
        #expect(CloudProfileMerge.orderedIDs(order, profiles: profiles) == [secondID, Fixture.profileID, firstID, newestID])
        #expect(CloudProfileMerge.orderedIDs(nil, profiles: profiles) == [Fixture.profileID, firstID, secondID, newestID])
    }

    @Test
    func repeatedProfileInputCannotResurrectDeletedUUIDOrTrap() {
        let deleted = Fixture.document(tombstone: CloudTombstone(version: Fixture.version(2), deletedAt: Fixture.createdAt))
        #expect(CloudProfileMerge.orderedIDs(nil, profiles: [Fixture.document(), deleted]).isEmpty)
        #expect(CloudProfileMerge.orderedIDs(nil, profiles: [Fixture.document(), Fixture.document()]) == [Fixture.profileID])
    }

    @Test
    func equalEmailsNeverMergeIndependentProfileUUIDs() throws {
        var fields = CloudProfileFields()
        fields.emailLink = CloudField(value: "same@example.invalid", version: Fixture.version(1))
        let a = Fixture.document(fields: fields)
        let b = Fixture.document(id: UUID(), fields: fields)
        #expect(throws: CloudSyncModelError.profileIdentityMismatch) { try CloudProfileMerge.merge(a, b) }
        #expect(Set(CloudProfileMerge.orderedIDs(nil, profiles: [a, b])) == Set([a.id, b.id]))
    }

    @Test
    func observationsUseCaptureDateThenDeviceAndDoNotChangeEditableFields() throws {
        let earlier = Fixture.createdAt
        let later = earlier.addingTimeInterval(1)
        let a = Fixture.document(observations: CloudProfileObservations(
            expiresAt: CloudObservation(value: earlier, capturedAt: later, deviceID: Fixture.deviceA),
            detectedNote: CloudObservation(value: "Older", capturedAt: earlier, deviceID: Fixture.deviceC)
        ))
        let b = Fixture.document(observations: CloudProfileObservations(
            expiresAt: CloudObservation(value: nil, capturedAt: later, deviceID: Fixture.deviceB),
            detectedNote: CloudObservation(value: "Newer", capturedAt: later, deviceID: Fixture.deviceA)
        ))
        let result = try CloudProfileMerge.merge(a, b)
        #expect(result.observations?.expiresAt?.value == nil)
        #expect(result.observations?.expiresAt?.deviceID == Fixture.deviceB)
        #expect(result.observations?.detectedNote?.value == "Newer")
        #expect(result.fields == CloudProfileFields())
    }

    @Test
    func lamportCounterAdvancesBeyondLocalAndAllObservedVersions() throws {
        let next = try CloudVersion.next(after: 10, observing: [Fixture.version(50), Fixture.version(20)], deviceID: Fixture.deviceB)
        #expect(next == Fixture.version(51, Fixture.deviceB))
        #expect(try CloudVersion.next(after: 60, observing: [next], deviceID: Fixture.deviceA).counter == 61)
        #expect(try CloudVersion.next(after: 0, observing: [], deviceID: Fixture.deviceA).counter == 1)
    }

    @Test
    func documentClockIncludesEveryEditableFieldTombstoneAndOpaqueExtension() throws {
        let stamp = Fixture.version(100)
        let changes: [(inout CloudProfileFields) -> Void] = [
            { $0.provider = CloudField(value: "codex", version: stamp) },
            { $0.label = CloudField(value: "A", version: stamp) },
            { $0.emailLink = CloudField(value: nil, version: stamp) },
            { $0.password = CloudField(value: nil, version: stamp) },
            { $0.twoFactorCode = CloudField(value: nil, version: stamp) },
            { $0.phoneNumber = CloudField(value: nil, version: stamp) },
            { $0.notes = CloudField(value: nil, version: stamp) },
            { $0.tags = CloudField(value: [], version: stamp) },
        ]
        for change in changes {
            var fields = CloudProfileFields()
            change(&fields)
            #expect(try Fixture.document(fields: fields).nextVersion(after: 0, deviceID: Fixture.deviceA).counter == 101)
        }
        let deleted = Fixture.document(tombstone: CloudTombstone(version: Fixture.version(200), deletedAt: Fixture.createdAt))
        #expect(try deleted.nextVersion(after: 0, deviceID: Fixture.deviceA).counter == 201)
        let document = Fixture.document(
            tombstone: CloudTombstone(version: Fixture.version(200), deletedAt: Fixture.createdAt),
            unknownFields: ["new-field": CloudField(value: Data([1]), version: Fixture.version(300))]
        )
        #expect(try document.nextVersion(after: 10, deviceID: Fixture.deviceB) == Fixture.version(301, Fixture.deviceB))
    }

    @Test
    func counterOverflowIsAnErrorRatherThanWraparound() {
        #expect(throws: CloudSyncModelError.counterOverflow) {
            try CloudVersion.next(after: .max, observing: [], deviceID: Fixture.deviceA)
        }
        #expect(throws: CloudSyncModelError.counterOverflow) {
            try CloudVersion.next(after: 0, observing: [Fixture.version(.max)], deviceID: Fixture.deviceA)
        }
    }

    @Test
    func unknownFieldBytesRoundTripAndMergeWithoutInterpretation() throws {
        let bytes = Data([0, 255, 128, 1, 0])
        let a = Fixture.document(unknownFields: ["future-field": CloudField(value: bytes, version: Fixture.version(2))])
        let b = Fixture.document(unknownFields: [
            "future-field": CloudField(value: Data([3]), version: Fixture.version(1)),
            "other-field": CloudField(value: Data([4]), version: Fixture.version(3)),
        ])
        let merged = try roundTrip(CloudProfileMerge.merge(a, b))
        #expect(merged.unknownFields["future-field"]?.value == bytes)
        #expect(merged.unknownFields["other-field"]?.value == Data([4]))
    }

    @Test
    func futureSchemaRoundTripsOpaqueDataButRefusesMergeClockAndPublication() throws {
        let future = Fixture.document(
            unknownFields: ["future": CloudField(value: Data([255, 0, 1]), version: Fixture.version(.max))],
            schemaVersion: 2
        )
        #expect(try roundTrip(future) == future)
        #expect(throws: CloudSyncModelError.unsupportedSchema(2)) { try future.validateForWriting() }
        #expect(throws: CloudSyncModelError.unsupportedSchema(2)) { try CloudRecordBody.profile(future).validateForWriting() }
        #expect(throws: CloudSyncModelError.unsupportedSchema(2)) { try CloudProfileMerge.merge(future, Fixture.document()) }
        #expect(throws: CloudSyncModelError.unsupportedSchema(2)) { try CloudProfileMerge.merge(Fixture.document(), future) }
        #expect(throws: CloudSyncModelError.unsupportedSchema(2)) { try future.nextVersion(after: 0, deviceID: Fixture.deviceA) }
        #expect(!CloudProfileMerge.isSessionEligible(Fixture.session(), for: future))
    }

    @Test
    func unsupportedOrderAndSessionCannotBePublishedOrAdopted() throws {
        let order = CloudOrderDocument(schemaVersion: 2, ids: [Fixture.profileID], version: Fixture.version(1))
        let session = CloudSessionDocument(
            schemaVersion: 2, profileID: Fixture.profileID, sourceDeviceID: Fixture.deviceA,
            sourceName: "Future Mac", kind: .desktop, revision: 1, capturedAt: Fixture.createdAt,
            payload: Data(UUID().uuidString.utf8)
        )
        #expect(try roundTrip(CloudRecordBody.order(order)) == .order(order))
        #expect(try roundTrip(CloudRecordBody.session(session)) == .session(session))
        #expect(throws: CloudSyncModelError.unsupportedSchema(2)) { try CloudRecordBody.order(order).validateForWriting() }
        #expect(throws: CloudSyncModelError.unsupportedSchema(2)) { try CloudRecordBody.session(session).validateForWriting() }
        #expect(!CloudProfileMerge.isSessionEligible(session, for: Fixture.document()))
    }

    @Test
    func conflictingValuesAtIdenticalVersionAreRejectedInsteadOfOrderDependent() {
        var a = CloudProfileFields()
        a.label = CloudField(value: "A", version: Fixture.version(1))
        var b = CloudProfileFields()
        b.label = CloudField(value: "B", version: Fixture.version(1))
        #expect(throws: CloudSyncModelError.conflictingVersion) { try CloudProfileMerge.merge(Fixture.document(fields: a), Fixture.document(fields: b)) }
        #expect(throws: CloudSyncModelError.conflictingVersion) { try CloudProfileMerge.merge(Fixture.document(fields: b), Fixture.document(fields: a)) }
    }

    @Test
    func portableRecordBodiesRoundTripSessionBytesAndOwnerEnvironment() throws {
        let session = Fixture.session(revision: .max)
        for body in [CloudRecordBody.profile(Fixture.document()), .order(CloudOrderDocument(ids: [Fixture.profileID], version: Fixture.version(1))), .session(session)] {
            #expect(try roundTrip(body) == body)
            try body.validateForWriting()
        }
        let development = CloudOwner(container: "iCloud.com.linda.CodexPlusBar", environment: .development, userRecordName: "synthetic-user")
        let production = CloudOwner(container: development.container, environment: .production, userRecordName: development.userRecordName)
        #expect(try roundTrip(development) == development)
        #expect(development != production)
    }

    @Test
    func projectionPreservesInactiveProviderAndOnlyEightEditableFields() throws {
        let secret = UUID().uuidString
        let browserID = UUID()
        let nativeID = UUID().uuidString
        let profile = PlusProfile(
            id: Fixture.profileID, provider: ProfileProvider(rawValue: "inactive-provider"), label: "Portable label",
            codexAccountKey: nativeID,
            codexSignIn: CodexSignInIdentity(accountID: nativeID, userID: nativeID, email: "local@example.invalid"),
            openCodeOpenAIAccount: OpenCodeOpenAIIdentity(accountID: nativeID, userID: nativeID, email: "local@example.invalid"),
            openChamberSignInCheck: OpenChamberSignInCheckRecord(identityKey: nativeID, outcome: .verified, checkedAt: Fixture.createdAt),
            emailLink: "https://example.invalid", detectedNote: "Local detected note",
            password: secret, twoFactorCode: secret, phoneNumber: "123", notes: "Portable notes",
            expiresAt: Fixture.createdAt, tags: [.active, .pending], webDataStoreID: browserID,
            sortOrder: 42, createdAt: Fixture.createdAt, lastRefreshAt: Fixture.createdAt, lastKnownState: .active
        )
        let values = CloudProfileProjection.values(from: profile)
        #expect(values == CloudProfileValues(
            provider: "inactive-provider", label: "Portable label", emailLink: "https://example.invalid",
            password: secret, twoFactorCode: secret, phoneNumber: "123", notes: "Portable notes", tags: ["active", "pending"]
        ))
        let encoded = try JSONEncoder().encode(values)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == Set(["provider", "label", "emailLink", "password", "twoFactorCode", "phoneNumber", "notes", "tags"]))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains(browserID.uuidString))
        #expect(!text.contains(nativeID))
        #expect(!text.contains("verified"))
        let document = Fixture.document(fields: CloudProfileFields(values: values, version: Fixture.version(1)))
        let decoded = try roundTrip(document)
        #expect(decoded.fields.provider?.value == "inactive-provider")
        #expect(decoded.fields == document.fields)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
