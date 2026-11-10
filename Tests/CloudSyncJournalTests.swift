import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CodexPlusBar

struct CloudSyncJournalTests {
    @Test(arguments: [CloudJournalIO.Operation.rename, .directorySync])
    func interruptedLocalSessionCompactionPreservesEvidenceAndInbox(operation: CloudJournalIO.Operation) async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let profile = CodexSignInFixture.profile(), source = UUID()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let middle = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let newest = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let first = try sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: []), source: source)
        let second = try sessionDocument(profile: profile,
            payload: .desktop(signIn: middle, consumed: [CloudSessionPayload.fingerprint(old.refreshToken)]), source: source, revision: 2)
        let third = try sessionDocument(profile: profile, payload: .desktop(signIn: newest, consumed: []), source: source, revision: 3)
        // Legacy state has no compacted evidence/indexes yet.
        for document in [first, second, third] { try await queueSession(document, in: journal) }
        let pending = try await journal.receive(recordName: "session.pending", ciphertext: Data([1, 2, 3]), transportManaged: true)
        let before = try await journal.load()
        let failing = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if name == "journal.json", event == operation { throw POSIXError(.EIO) }
        })
        await #expect(throws: (any Error).self) { try await failing.transaction { $0.compactLocalSessions() } }
        let restarted = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await restarted.transaction { $0.compactLocalSessions() }
        let after = try await restarted.load()
        #expect(after.sessions.values.map(\.revision) == [3])
        #expect(after.recordGenerations == before.recordGenerations)
        #expect(after.payloadDigests == before.payloadDigests)
        #expect(after.receivedEnvelopes == before.receivedEnvelopes)
        #expect(after.receipts == before.receipts)
        #expect(after.transport?.pendingSessionDeletes.isEmpty == true)
        #expect(after.transport?.deletedSessions.isEmpty == true)
        // An old send may have reached the server before its ack was journaled.
        // Explicit later profile deletion must still know that cloud record name.
        #expect(after.transport?.sessionProfiles[CloudRecordCodec.recordName(for: .session(first))] == profile.id)
        #expect(try await restarted.ciphertext(for: pending.id) == Data([1, 2, 3]))
        let stale = try sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: []), source: UUID())
        #expect(!after.canPublishSession(stale))
        #expect(after.latestSessionRevision(profileID: profile.id, sourceDeviceID: source, kind: .desktop) == 3)
        await #expect(throws: CloudJournalError.invalidTransition) {
            try await restarted.transaction { $0.consumedSessionGenerations = nil }
        }
        await #expect(throws: CloudJournalError.invalidTransition) {
            try await restarted.transaction { $0.sessionRevisionHighWater = nil }
        }
    }

    @Test func compactionRestartsAfterUnlinkButBeforeCleanupListClears() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let envelope = try await journal.receive(recordName: Self.record, ciphertext: Data([4]), transportManaged: true)
        try await journal.transaction { try $0.beginApplying(envelope.id, postProjection: .init(profiles: []), documents: [:]) }
        try await journal.transaction { _ = try $0.replay(envelope.id, catalog: .trusted(.init(profiles: []))) }
        let counter = CompactionRenameCounter()
        let failing = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if name == "journal.json", event == .rename, counter.next() == 2 { throw POSIXError(.EIO) }
        })
        #expect(throws: (any Error).self) { try failing.compactCompletedCatalog() }
        #expect(!FileManager.default.fileExists(atPath: f.asset(envelope).path))
        let reopened = CloudSyncJournal(root: f.root, owner: Self.owner)
        #expect(try await reopened.load().catalogAssetCleanup == [envelope.asset.fileName])
        try reopened.compactCompletedCatalog()
        #expect(try await reopened.load().catalogAssetCleanup == nil)
        #expect(try await reopened.load().completedCatalogReceipts?[Self.record] == envelope.id)
    }

    @Test(arguments: [CloudJournalIO.Operation.rename, .directorySync, .cleanupUnlink])
    func interruptedCatalogCompactionRetriesWithoutTouchingPendingOrSessionAssets(operation: CloudJournalIO.Operation) async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "kept")), deviceID: Self.device) }
        try await journal.transaction { try $0.reconcile(.trusted(.init(profiles: [])), deviceID: Self.device) }
        let envelope = try await journal.receive(recordName: Self.record, ciphertext: Data([1]), transportManaged: true)
        let pending = try await journal.receive(recordName: "profile.pending", ciphertext: Data([2]), transportManaged: true)
        let session = try await journal.receive(recordName: "session.kept", ciphertext: Data([3]), transportManaged: true)
        try await journal.transaction { state in
            state.transport?.processedInbox.formUnion([envelope.id, session.id])
            state.transport?.sessionReceipts[session.recordName] = session.id
            state.transport?.sessionProfiles[session.recordName] = Self.id
            state.transport?.sessionDigests[session.recordName] = Data(repeating: 7, count: 32)
            try state.beginApplying(envelope.id, postProjection: state.committedProjection, documents: [:])
        }
        try await journal.transaction { state in _ = try state.replay(envelope.id, catalog: .trusted(state.committedProjection)) }
        let before = try await journal.load()
        let failing = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if event == operation, name == "journal.json" || event == .cleanupUnlink { throw POSIXError(.EIO) }
        })
        #expect(throws: (any Error).self) { try failing.compactCompletedCatalog() }
        #expect(FileManager.default.fileExists(atPath: f.asset(envelope).path))
        let restarted = CloudSyncJournal(root: f.root, owner: Self.owner)
        try restarted.compactCompletedCatalog()
        try restarted.compactCompletedCatalog()
        let after = try await restarted.load()
        #expect(after.profiles == before.profiles)
        #expect(after.recordGenerations == before.recordGenerations)
        #expect(after.dirtyGenerations == before.dirtyGenerations)
        #expect(after.completedCatalogReceipts?[Self.record] == envelope.id)
        #expect(after.receipts[envelope.id] == nil)
        #expect(after.catalogAssetCleanup == nil)
        #expect(after.transport?.inboxOrder == [pending.id, session.id])
        #expect(after.transport?.sessionReceipts == before.transport?.sessionReceipts)
        #expect(after.transport?.sessionDigests == before.transport?.sessionDigests)
        #expect(try await restarted.pendingInboxItem(envelope.id) == nil)
        #expect(try await restarted.ciphertext(for: pending.id) == Data([2]))
        #expect(try await restarted.ciphertext(for: session.id) == Data([3]))
        #expect(!FileManager.default.fileExists(atPath: f.asset(envelope).path))
    }

    private static let owner = CloudOwner(container: "iCloud.com.linda.CodexPlusBar", environment: .development,
                                          userRecordName: "synthetic-owner")
    private static let id = CloudSyncTestSupport.profileID
    private static let device = CloudSyncTestSupport.deviceA
    private static let record = CloudJournalState.profileRecordName(id)

    @Test func committedCatalogEditIsRecoveredBeforeEnqueue() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let original = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await original.transaction { try $0.reconcile(.trusted(Self.catalog(label: "original")), deviceID: Self.device) }
        let catalog = Self.catalog(label: "committed edit")
        // Simulates the controller committing its catalog, then dying before notifying sync.
        let file = f.base.appendingPathComponent("committed-catalog.json")
        try JSONEncoder().encode(catalog).write(to: file)
        let committed = try JSONDecoder().decode(CloudCatalogProjection.self, from: Data(contentsOf: file))
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { try $0.reconcile(.trusted(committed), deviceID: Self.device) }
        let reopened = try await CloudSyncJournal(root: f.root, owner: Self.owner).load()
        #expect(reopened.profiles[Self.record]?.fields.label?.value == "committed edit")
        #expect(reopened.dirtyGenerations[Self.record] == 2)
        #expect(reopened.committedProjection == catalog)
        let clock = reopened.lamportCounter
        try await journal.transaction { try $0.reconcile(.trusted(committed), deviceID: Self.device) }
        #expect(try await journal.load().lamportCounter == clock)
    }

    @Test func acknowledgingSevenCannotClearEightOrReuseAnAcknowledgedGeneration() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let seventh = try await journal.transaction { state in
            for index in 1...7 {
                try state.reconcile(.trusted(Self.catalog(label: "edit \(index)")), deviceID: Self.device)
            }
            return try #require(state.sentRevision(for: Self.record))
        }
        #expect(seventh.generation == 7)
        try await journal.transaction { state in
            try state.reconcile(.trusted(Self.catalog(label: "edit 8")), deviceID: Self.device)
            state.acknowledge(seventh)
        }
        let reopened = try await CloudSyncJournal(root: f.root, owner: Self.owner).load()
        #expect(reopened.dirtyGenerations[Self.record] == 8)
        let eighth = try #require(reopened.sentRevision(for: Self.record))
        try await journal.transaction { state in
            state.acknowledge(CloudSentRevision(recordName: eighth.recordName, generation: 8, payloadDigest: Data(repeating: 0, count: 32)))
        }
        #expect(try await journal.load().dirtyGenerations[Self.record] == 8)
        try await journal.transaction { $0.acknowledge(eighth, systemFields: Data([1, 2, 3])) }
        #expect(try await journal.load().dirtyGenerations[Self.record] == nil)
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "edit 9")), deviceID: Self.device) }
        let final = try await journal.load()
        #expect(final.dirtyGenerations[Self.record] == 9)
        #expect(final.systemFields[Self.record] == Data([1, 2, 3]))
    }

    @Test func ownerAndEnvironmentPartitionsNeverMixButDevicePreferencesAreShared() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let first = CloudSyncJournal(root: f.root, owner: Self.owner)
        let identity = try await first.deviceState()
        #expect(!identity.preferences.enabled)
        #expect(identity.preferences.includeSavedSessions)
        try await first.setPreferences(.init(enabled: true, paused: true, includeSavedSessions: false))
        try await first.transaction { $0.engineState = Data([9]) }
        for owner in [CloudOwner(container: Self.owner.container, environment: .production, userRecordName: Self.owner.userRecordName),
                      CloudOwner(container: Self.owner.container, environment: .development, userRecordName: "other/../owner"),
                      CloudOwner(container: "other-container", environment: .development, userRecordName: Self.owner.userRecordName)] {
            let other = CloudSyncJournal(root: f.root, owner: owner)
            #expect(try await other.load().engineState == nil)
            let device = try await other.deviceState()
            #expect(device.deviceID == identity.deviceID)
            #expect(device.preferences.paused)
            #expect(!device.preferences.includeSavedSessions)
            #expect(CloudSyncPaths(root: f.root).partition(for: owner) != CloudSyncPaths(root: f.root).partition(for: Self.owner))
        }
    }

    @Test func remoteReceiptReplaysCommittedApplyOnceWithoutLocalClock() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let envelope = try await journal.receive(recordName: Self.record, metadata: Data([1]), systemFields: Data([2]),
                                                 ciphertext: Data(UUID().uuidString.utf8), engineState: Data([3]))
        let post = Self.catalog(label: "remote")
        let document = CloudProfileDocument(id: Self.id, createdAt: CloudSyncTestSupport.createdAt,
            fields: .init(values: post.profiles[0].values, version: .init(counter: 42, deviceID: CloudSyncTestSupport.deviceB)))
        try await journal.transaction {
            try $0.beginApplying(envelope.id, postProjection: post, documents: [Self.record: .profile(document)])
        }
        let reopened = CloudSyncJournal(root: f.root, owner: Self.owner)
        let before = try await reopened.transaction { try $0.replay(envelope.id, catalog: .trusted(.init(profiles: []))) }
        #expect(before == .needsApplication(post))
        #expect(try await reopened.load().receipts[envelope.id]?.phase == .applying)
        // Real catalog commit belongs to Task 5; supply its committed projection after a simulated restart.
        let after = try await reopened.transaction { try $0.replay(envelope.id, catalog: .trusted(post)) }
        #expect(after == .completed)
        let second = try await reopened.transaction { try $0.replay(envelope.id, catalog: .trusted(post)) }
        #expect(second == .alreadyApplied)
        try await reopened.transaction { try $0.reconcile(.trusted(post), deviceID: Self.device) }
        let state = try await reopened.load()
        #expect(state.lamportCounter == 42)
        #expect(state.dirtyGenerations.isEmpty)
        #expect(state.profiles[Self.record] == document)
        #expect(state.receipts[envelope.id]?.phase == .applied)
        #expect(state.engineState == Data([3]))
        #expect(try await reopened.ciphertext(for: envelope.id) == Data(contentsOf: f.asset(envelope)))
        try await reopened.removeAppliedEnvelope(envelope.id)
        #expect(!FileManager.default.fileExists(atPath: f.asset(envelope).path))
        #expect(try await reopened.load().receipts[envelope.id]?.phase == .applied)
    }

    @Test func missingUnreadableAndDivergedCatalogsNeverCreateTombstonesOrGuessReplay() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "local")), deviceID: Self.device) }
        let previous = try await journal.load()
        for input in [CloudCatalogRead.missing, .unreadable] {
            await #expect(throws: CloudJournalError.catalogUnavailable) {
                try await journal.transaction { try $0.reconcile(input, deviceID: Self.device) }
            }
        }
        #expect(try await journal.load() == previous)
        let envelope = try await journal.receive(recordName: Self.record, ciphertext: Data([4]))
        try await journal.transaction { try $0.beginApplying(envelope.id, postProjection: Self.catalog(label: "remote"), documents: [:]) }
        for input in [CloudCatalogRead.missing, .unreadable, .trusted(Self.catalog(label: "unrelated"))] {
            await #expect(throws: (any Error).self) {
                try await journal.transaction { try $0.replay(envelope.id, catalog: input) }
            }
        }
        #expect(try await journal.load().receipts[envelope.id]?.phase == .applying)
        #expect(try await journal.load().profiles[Self.record]?.tombstone == nil)
    }

    @Test func trustedDeletionSurvivesReappearanceAndEditsStampOnlyChangedFields() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "first")), deviceID: Self.device) }
        let original = try await journal.load()
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "second")), deviceID: Self.device) }
        let edited = try await journal.load()
        #expect(edited.profiles[Self.record]?.fields.provider == original.profiles[Self.record]?.fields.provider)
        #expect(edited.profiles[Self.record]?.fields.label?.version != original.profiles[Self.record]?.fields.label?.version)
        try await journal.transaction { try $0.reconcile(.trusted(.init(profiles: [])), deviceID: Self.device) }
        let deleted = try await journal.load()
        #expect(deleted.profiles[Self.record]?.tombstone != nil)
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "must not resurrect")), deviceID: Self.device) }
        #expect(try await journal.load().profiles[Self.record] == deleted.profiles[Self.record])
    }

    @Test(arguments: [CloudJournalIO.Operation.write, .fileSync, .rename])
    func failedReplacementKeepsCursorDirtyStateAndPendingCiphertext(operation: CloudJournalIO.Operation) async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let normal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await normal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "local")), deviceID: Self.device) }
        let envelope = try await normal.receive(recordName: Self.record, ciphertext: Data([7, 8]), engineState: Data([1]))
        let before = try await normal.load()
        let bytes = try Data(contentsOf: f.journal)
        let failing = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if name == "journal.json", event == operation { throw POSIXError(event == .write ? .ENOSPC : .EIO) }
        })
        await #expect(throws: (any Error).self) {
            try await failing.transaction { $0.engineState = Data([2]); $0.dirtyGenerations.removeAll() }
        }
        #expect(try Data(contentsOf: f.journal) == bytes)
        #expect(try await normal.load() == before)
        #expect(try await normal.ciphertext(for: envelope.id) == Data([7, 8]))
        await #expect(throws: (any Error).self) {
            try await failing.receive(recordName: "another", ciphertext: Data([6]), engineState: Data([4]))
        }
        #expect(try await normal.load() == before)
        let inboxFiles = try FileManager.default.contentsOfDirectory(at: f.inbox, includingPropertiesForKeys: nil)
        #expect(inboxFiles.count == 2) // Unreferenced durable copy is retained after journal failure.
    }

    @Test func directorySyncFailureReportsUncertainCommitAndReloadsRenamedState() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let normal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let envelope = try await normal.receive(recordName: Self.record, ciphertext: Data([9]))
        let uncertain = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if name == "journal.json", event == .directorySync { throw POSIXError(.EIO) }
        })
        await #expect(throws: CloudJournalError.commitUncertain("journal.json")) {
            try await uncertain.transaction { $0.engineState = Data([5]) }
        }
        #expect(try await uncertain.load().engineState == Data([5]))
        #expect(try await normal.load().engineState == Data([5]))
        #expect(try await normal.ciphertext(for: envelope.id) == Data([9]))
        try await normal.transaction { $0.lastSuccess = Date(timeIntervalSince1970: 100) }
        #expect(try await normal.load().engineState == Data([5]))
    }

    @Test func failedAssetPersistenceCannotAdvanceCursorOrReferenceMissingBytes() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { $0.engineState = Data([1]) }
        let failing = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if name.hasSuffix(".asset"), event == .rename { throw POSIXError(.ENOSPC) }
        })
        await #expect(throws: (any Error).self) {
            try await failing.receive(recordName: Self.record, ciphertext: Data([5]), engineState: Data([2]))
        }
        let state = try await journal.load()
        #expect(state.engineState == Data([1]))
        #expect(state.receivedEnvelopes.isEmpty)
    }

    @Test func malformedTruncatedOversizedAndWrongOwnerStateFailInsteadOfResetting() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { $0.engineState = Data([1]) }
        let valid = try Data(contentsOf: f.journal)
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["schemaVersion"] = 99
        var malformed = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        malformed.removeValue(forKey: "dirtyGenerations")
        for bytes in [Data(valid.prefix(valid.count / 2)), Data("{}".utf8),
                      try JSONSerialization.data(withJSONObject: object), try JSONSerialization.data(withJSONObject: malformed)] {
            try bytes.write(to: f.journal)
            await #expect(throws: (any Error).self) { try await journal.load() }
            await #expect(throws: (any Error).self) { try await journal.transaction { $0.engineState = nil } }
            #expect(try Data(contentsOf: f.journal) == bytes)
        }
        try valid.write(to: f.journal)
        let handle = try FileHandle(forWritingTo: f.journal)
        try handle.truncate(atOffset: UInt64(CloudSyncJournal.maximumJournalBytes + 1)); try handle.close()
        await #expect(throws: CloudJournalError.tooLarge) { try await journal.load() }
        var wrongOwner = try JSONDecoder().decode(CloudJournalState.self, from: valid)
        wrongOwner.owner = CloudOwner(container: "wrong", environment: .development, userRecordName: "wrong")
        try JSONEncoder().encode(wrongOwner).write(to: f.journal)
        await #expect(throws: CloudJournalError.ownerMismatch) { try await journal.load() }
    }

    @Test func invalidTransactionAndMissingAssetAreRejectedWithoutMutation() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let envelope = try await journal.receive(recordName: Self.record, ciphertext: Data([1, 2]))
        let before = try Data(contentsOf: f.journal)
        await #expect(throws: (any Error).self) {
            try await journal.transaction { $0.dirtyGenerations["invalid"] = 0 }
        }
        #expect(try Data(contentsOf: f.journal) == before)
        try FileManager.default.removeItem(at: f.asset(envelope))
        await #expect(throws: (any Error).self) { try await journal.transaction { $0.engineState = Data([3]) } }
        #expect(try Data(contentsOf: f.journal) == before)
    }

    @Test func privatePathsRejectSymlinksNonregularTargetsAndAccountRootPlacement() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        _ = try await journal.deviceState()
        try await journal.transaction { $0.engineState = Data([1]) }
        for url in [f.root, f.journal.deletingLastPathComponent(), f.inbox] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
        for url in [f.journal, CloudSyncPaths(root: f.root).deviceFile] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        let outside = f.base.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.journal)
        try FileManager.default.createSymbolicLink(at: f.journal, withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await journal.transaction { $0.engineState = nil } }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched")
        try FileManager.default.removeItem(at: f.journal)
        #expect(mkfifo(f.journal.path, 0o600) == 0)
        await #expect(throws: (any Error).self) { try await journal.load() }
        let linked = f.base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: f.root)
        await #expect(throws: (any Error).self) { try await CloudSyncJournal(root: linked, owner: Self.owner).load() }
        for component in ["CodexPlusBar", "codexplusbar"] {
            await #expect(throws: CloudJournalError.unsafePath) {
                try await CloudSyncJournal(root: f.base.appendingPathComponent(component + "/CloudSync"), owner: Self.owner).load()
            }
        }
    }

    @Test func concurrentJournalInstancesDoNotLoseCommittedTransactions() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let a = CloudSyncJournal(root: f.root, owner: Self.owner)
        let b = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { try await (index.isMultiple(of: 2) ? a : b).transaction { $0.lamportCounter += 1 } }
            }
            try await group.waitForAll()
        }
        #expect(try await a.load().lamportCounter == 20)
    }

    @Test func canonicalOwnerIdentityAndInvalidOwnerDoNotCreateAmbiguousPartitions() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let composed = CloudOwner(container: "container", environment: .development, userRecordName: "caf\u{00E9}")
        let decomposed = CloudOwner(container: "container", environment: .development, userRecordName: "cafe\u{0301}")
        #expect(composed == decomposed)
        let a = CloudSyncJournal(root: f.root, owner: composed)
        try await a.transaction { $0.engineState = Data([6]) }
        let b = CloudSyncJournal(root: f.root, owner: decomposed)
        #expect(try await b.load().engineState == Data([6]))
        let invalidRoot = f.base.appendingPathComponent("invalid-owner")
        await #expect(throws: CloudJournalError.invalidState) {
            try await CloudSyncJournal(root: invalidRoot,
                owner: .init(container: "container", environment: .development, userRecordName: "")).load()
        }
        #expect(!FileManager.default.fileExists(atPath: invalidRoot.path))
    }

    @Test(arguments: [CloudJournalIO.Operation.rename, .directorySync])
    func failedCleanupNeverDeletesCiphertext(operation: CloudJournalIO.Operation) async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let envelope = try await journal.receive(recordName: Self.record, ciphertext: Data([5, 6]))
        await #expect(throws: CloudJournalError.invalidTransition) { try await journal.removeAppliedEnvelope(envelope.id) }
        try await journal.transaction {
            try $0.beginApplying(envelope.id, postProjection: .init(profiles: []), documents: [:])
        }
        _ = try await journal.transaction { try $0.replay(envelope.id, catalog: .trusted(.init(profiles: []))) }
        let failing = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if name == "journal.json", event == operation { throw POSIXError(.EIO) }
        })
        await #expect(throws: (any Error).self) { try await failing.removeAppliedEnvelope(envelope.id) }
        #expect(try Data(contentsOf: f.asset(envelope)) == Data([5, 6]))
        let state = try await journal.load()
        #expect(state.receipts[envelope.id]?.phase == .applied)
        #expect((state.receivedEnvelopes[envelope.id] != nil) == (operation == .rename))
    }

    @Test func uncertainAssetRenameCanBeRetriedWithTheSameReceiptIdentity() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let id = UUID()
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, name in
            if name.hasSuffix(".asset"), event == .directorySync { throw POSIXError(.EIO) }
        })
        await #expect(throws: CloudJournalError.commitUncertain(id.uuidString.lowercased() + ".asset")) {
            try await journal.receive(id: id, recordName: Self.record, ciphertext: Data([7]), engineState: Data([9]))
        }
        #expect(try await journal.load().engineState == nil)
        let envelope = try await journal.receive(id: id, recordName: Self.record, ciphertext: Data([7]), engineState: Data([9]))
        #expect(envelope.id == id)
        #expect(try await journal.load().engineState == Data([9]))
        #expect(try await journal.ciphertext(for: id) == Data([7]))
    }

    @Test func assetLimitTamperingAndBroadPermissionsAreRejected() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let limit = 16 * 1_024 * 1_024
        let envelope = try await journal.receive(recordName: Self.record, ciphertext: Data(repeating: 8, count: limit))
        #expect(try await journal.ciphertext(for: envelope.id).count == limit)
        let permissions = try FileManager.default.attributesOfItem(atPath: f.asset(envelope).path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let before = try Data(contentsOf: f.journal)
        await #expect(throws: CloudJournalError.tooLarge) {
            try await journal.receive(recordName: Self.record, ciphertext: Data(repeating: 8, count: limit + 1), engineState: Data([4]))
        }
        try Data(repeating: 9, count: limit).write(to: f.asset(envelope))
        await #expect(throws: CloudJournalError.assetMismatch) { try await journal.load() }
        #expect(try Data(contentsOf: f.journal) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.asset(envelope).path)
        await #expect(throws: CloudJournalError.unsafePath) { try await journal.load() }
    }

    @Test func deviceCorruptionCannotSilentlyChangeIdentityOrPreferences() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        _ = try await journal.deviceState()
        let file = CloudSyncPaths(root: f.root).deviceFile
        let bytes = Data("{\"schemaVersion\":1}".utf8)
        try bytes.write(to: file)
        await #expect(throws: CloudJournalError.corruptState) { try await journal.deviceState() }
        await #expect(throws: CloudJournalError.corruptState) { try await journal.setPreferences(.init(enabled: true)) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func reloadMustReestablishDurabilityBeforeReturningVisibleState() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { $0.engineState = Data([8]) }
        let failing = CloudSyncJournal(root: f.root, owner: Self.owner, io: .init { event, _ in
            if event == .recoverySync { throw POSIXError(.EIO) }
        })
        await #expect(throws: CloudJournalError.commitUncertain("journal.json")) { try await failing.load() }
        await #expect(throws: CloudJournalError.commitUncertain("journal.json")) {
            try await failing.transaction { $0.engineState = Data([9]) }
        }
        #expect(try await journal.load().engineState == Data([8]))
    }

    @Test(arguments: ["ancestor", "root", "owners", "partition", "inbox"])
    func failedDirectoryLinkSyncBlocksSameInstanceAndRestartedRetries(level: String) async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let ancestor = f.base.appendingPathComponent("new-ancestor")
        let root = ancestor.appendingPathComponent("CodexPlusBar CloudSync")
        let partition = CloudSyncPaths(root: root).partition(for: Self.owner)
        let targets = ["ancestor": ancestor, "root": root, "owners": root.appendingPathComponent("owners"),
                       "partition": partition, "inbox": partition.appendingPathComponent("inbox")]
        let target = try #require(targets[level])
        let journalFile = partition.appendingPathComponent("journal.json")
        let io = CloudJournalIO { event, name in
            if event == .directoryLinkSync, name == target.lastPathComponent { throw POSIXError(.EIO) }
        }
        let original = CloudSyncJournal(root: root, owner: Self.owner, io: io)
        // mkdir succeeds, but persistence of the new name in its parent fails.
        await #expect(throws: (any Error).self) {
            try await original.transaction { $0.engineState = Data([1]) }
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: journalFile.path))

        // A visible directory cannot bypass the failed sync, even with no in-memory history.
        let restarted = CloudSyncJournal(root: root, owner: Self.owner, io: io)
        for retry in [original, restarted] {
            await #expect(throws: (any Error).self) {
                try await retry.transaction { $0.engineState = Data([2]) }
            }
            #expect(!FileManager.default.fileExists(atPath: journalFile.path))
        }

        let recovered = CloudSyncJournal(root: root, owner: Self.owner)
        try await recovered.transaction { $0.engineState = Data([3]) }
        #expect(try await CloudSyncJournal(root: root, owner: Self.owner).load().engineState == Data([3]))
        let committed = try Data(contentsOf: journalFile)
        await #expect(throws: (any Error).self) { try await restarted.load() }
        await #expect(throws: (any Error).self) {
            try await restarted.transaction { $0.engineState = Data([4]) }
        }
        #expect(try Data(contentsOf: journalFile) == committed)
    }

    @Test func approvedRecordNamesPersistReconcileAndRejectSessionNamespaceCollisions() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let profileName = "profile.10000000-0000-0000-0000-000000000001"
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "approved")), deviceID: Self.device) }
        let reopened = try await CloudSyncJournal(root: f.root, owner: Self.owner).load()
        #expect(Set(reopened.profiles.keys) == [profileName])
        #expect(reopened.dirtyGenerations == [profileName: 1, "order.v1": 1])
        #expect(reopened.sentRevision(for: profileName)?.recordName == profileName)
        #expect(reopened.sentRevision(for: "order.v1")?.recordName == "order.v1")
        let before = try Data(contentsOf: f.journal)
        let session = CloudSyncTestSupport.session()
        for name in [profileName, "order.v1"] {
            await #expect(throws: CloudJournalError.invalidState) {
                try await journal.transaction { $0.sessions[name] = session }
            }
        }
        #expect(try Data(contentsOf: f.journal) == before)
        let envelope = try await journal.receive(recordName: profileName, ciphertext: Data([1]))
        try await journal.transaction { state in
            try state.beginApplying(envelope.id, postProjection: state.committedProjection,
                                    documents: ["order.v1": .order(try #require(state.order))])
        }
        #expect(try await journal.load().receipts[envelope.id]?.plan?.documents["order.v1"] != nil)
    }

    @Test func explicitClearAndSendGenerationOverflowPreserveUnchangedFields() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let before = CloudCatalogProjection(profiles: [.init(id: Self.id, createdAt: CloudSyncTestSupport.createdAt,
            values: .init(provider: "inactive", label: "kept", notes: "clear me", tags: ["unknown-tag"]))])
        let cleared = CloudCatalogProjection(profiles: [.init(id: Self.id, createdAt: CloudSyncTestSupport.createdAt,
            values: .init(provider: "inactive", label: "kept", notes: nil, tags: ["unknown-tag"]))])
        try await journal.transaction { try $0.reconcile(.trusted(before), deviceID: Self.device) }
        let original = try await journal.load()
        try await journal.transaction { try $0.reconcile(.trusted(cleared), deviceID: Self.device) }
        let state = try await journal.load()
        let notes = try #require(state.profiles[Self.record]?.fields.notes)
        #expect(notes.value == nil)
        #expect(notes.version != original.profiles[Self.record]?.fields.notes?.version)
        #expect(state.profiles[Self.record]?.fields.label == original.profiles[Self.record]?.fields.label)
        #expect(state.profiles[Self.record]?.fields.tags == original.profiles[Self.record]?.fields.tags)
        try await journal.transaction { $0.recordGenerations[Self.record] = .max; $0.dirtyGenerations[Self.record] = .max }
        let bytes = try Data(contentsOf: f.journal)
        await #expect(throws: CloudSyncModelError.counterOverflow) {
            try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "new")), deviceID: Self.device) }
        }
        #expect(try Data(contentsOf: f.journal) == bytes)
    }

    @Test func duplicateProjectionAndCounterOverflowLeavePreviousCommitUntouched() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "saved")), deviceID: Self.device) }
        let row = Self.catalog(label: "duplicate").profiles[0]
        await #expect(throws: CloudJournalError.invalidState) {
            try await journal.transaction { try $0.reconcile(.trusted(.init(profiles: [row, row])), deviceID: Self.device) }
        }
        try await journal.transaction { $0.lamportCounter = .max }
        let before = try Data(contentsOf: f.journal)
        await #expect(throws: CloudSyncModelError.counterOverflow) {
            try await journal.transaction { try $0.reconcile(.trusted(Self.catalog(label: "overflow")), deviceID: Self.device) }
        }
        #expect(try Data(contentsOf: f.journal) == before)
        #expect(try await journal.load().profiles[Self.record]?.fields.label?.value == "saved")
    }

    @Test func sessionRestoreAndEnginePlaceholdersRoundTripWithoutLosingOpaqueBytes() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let session = CloudSyncTestSupport.session()
        let projection = Self.catalog(label: "restored")
        let intent = CloudRestoreIntent(id: UUID(), expectedPreDigest: Data(repeating: 1, count: 32),
                                        expectedPostDigest: try projection.digest(), postProjection: projection)
        try await journal.transaction { state in
            state.sessions["session-test"] = session
            try state.markDirty(recordName: "session-test", body: .session(session))
            state.restoreIntent = intent
            state.engineState = Data([0, 255, 12])
            state.systemFields["session-test"] = Data([255, 0, 13])
            state.lastSuccess = Date(timeIntervalSince1970: 1_234)
        }
        let state = try await CloudSyncJournal(root: f.root, owner: Self.owner).load()
        #expect(state.sessions["session-test"] == session)
        #expect(state.restoreIntent == intent)
        #expect(state.engineState == Data([0, 255, 12]))
        #expect(state.systemFields["session-test"] == Data([255, 0, 13]))
        #expect(state.lastSuccess == Date(timeIntervalSince1970: 1_234))
        #expect(state.dirtyGenerations["session-test"] == 1)
        await #expect(throws: CloudJournalError.applicationPending) {
            try await journal.transaction { try $0.reconcile(.trusted(projection), deviceID: Self.device) }
        }
    }

    @Test func realBackupRestoreSwapExcludesAndPreservesJournalAndDeviceIdentity() async throws {
        let f = try JournalFixture(); defer { f.cleanUp() }
        let accountRoot = f.base.appendingPathComponent("CodexPlusBar")
        let profile = backupTestProfile()
        let store = ProfileCatalogStore(fileURL: accountRoot.appendingPathComponent("profiles.json"))
        try store.saveProfiles([profile])
        let journal = CloudSyncJournal(root: f.root, owner: Self.owner)
        let device = try await journal.deviceState()
        try await journal.transaction { $0.engineState = Data([8]) }
        let service = BackupService(root: accountRoot)
        let archive = f.base.appendingPathComponent("export.backup")
        try await service.export(to: archive, password: "synthetic backup password",
                                 manifest: .init(profileCount: 1, preferences: .init(), cookies: [:]))
        let prepared = try await service.prepare(from: archive, password: "synthetic backup password")
        let paths = try BackupArchive.regularFiles(in: prepared.directory).map(\.0)
        #expect(Set(paths) == ["manifest.json", "Data/profiles.json"])
        try store.saveProfiles([])
        try await service.commit(prepared)
        #expect(try store.loadProfiles().first?.id == profile.id)
        let reopened = CloudSyncJournal(root: f.root, owner: Self.owner)
        #expect(try await reopened.deviceState() == device)
        #expect(try await reopened.load().engineState == Data([8]))
    }

    private static func catalog(label: String) -> CloudCatalogProjection {
        .init(profiles: [.init(id: id, createdAt: CloudSyncTestSupport.createdAt,
                              values: .init(provider: "inactive-provider", label: label))])
    }

    private struct JournalFixture {
        let base: URL
        var root: URL { base.appendingPathComponent("CodexPlusBar CloudSync") }
        var partition: URL { CloudSyncPaths(root: root).partition(for: CloudSyncJournalTests.owner) }
        var journal: URL { partition.appendingPathComponent("journal.json") }
        var inbox: URL { partition.appendingPathComponent("inbox") }
        init() throws {
            base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cloud-journal-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func asset(_ envelope: CloudReceivedEnvelope) -> URL { inbox.appendingPathComponent(envelope.asset.fileName) }
        func cleanUp() { try? FileManager.default.removeItem(at: base) }
    }
}

private final class CompactionRenameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
