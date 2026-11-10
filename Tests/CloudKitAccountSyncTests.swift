import CloudKit
import Foundation
import Testing
@testable import CodexPlusBar

struct CloudKitAccountSyncTests {
    @Test func compactedLocalRecordStillRejectsConflictingRemoteReplay() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile(), source = UUID()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let first = try sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: []), source: source)
        let second = try sessionDocument(profile: profile, payload: .desktop(signIn: next, consumed: []), source: source, revision: 2)
        try await stageProfile(profile, in: f.journal)
        for document in [first, second] { try await queueSession(document, in: f.journal) }
        try await f.journal.transaction { $0.compactLocalSessions() }
        try await f.startReady()
        // Reuses a compacted source revision with new authenticated consumption.
        let conflicting = try f.record(.session(sessionDocument(profile: profile,
            payload: .desktop(signIn: old, consumed: [CloudSessionPayload.fingerprint(next.refreshToken)]), source: source)))
        defer { conflicting.lease.release() }
        await f.driver.emit(.fetched(records: [conflicting.record], deletions: []))
        let state = try await f.journal.load()
        #expect(state.transport?.processedInbox.isEmpty == true)
        #expect(state.canPublishSession(second))
        let batch = try #require(await f.driver.batch())
        #expect(batch.recordsToSave.map(\.recordID.recordName) == [CloudRecordCodec.recordName(for: .session(second))])
        let valid = try f.record(.session(second)); defer { valid.lease.release() }
        await f.driver.emit(.fetched(records: [valid.record], deletions: []))
        #expect(try await CloudSessionInbox(journal: f.journal, keys: f.keys).summaries(for: profile).map(\.revision) == [2])
        await f.transport.stop()
    }

    @Test func legacyProcessedSessionAcquiresDurableConsumptionOnRestart() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        try await stageProfile(profile, in: f.journal)
        try await queueSession(sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: [])), in: f.journal)
        let document = try sessionDocument(profile: profile,
            payload: .desktop(signIn: next, consumed: [CloudSessionPayload.fingerprint(old.refreshToken)]))
        let encoded = try f.record(.session(document)); defer { encoded.lease.release() }
        let envelope = try f.codec.envelope(from: encoded.record)
        try await f.journal.receive(id: envelope.id, recordName: envelope.recordName,
            metadata: CloudJournalCoding.encode(envelope.routing), systemFields: envelope.systemFields,
            ciphertext: envelope.ciphertext, transportManaged: true)
        try await f.journal.transaction {
            $0.transport?.processedInbox.insert(envelope.id)
            $0.transport?.sessionReceipts[envelope.recordName] = envelope.id
            $0.transport?.sessionDigests[envelope.recordName] = CloudJournalCoding.digest(try CloudJournalCoding.encode(document))
        }
        try await f.startReady()
        #expect(await f.driver.batch() == nil)
        #expect(await f.keys.writers == 0)
        #expect(try await f.journal.load().consumedSessionGenerations?.isEmpty == false)
        await f.transport.stop()
    }

    @Test(arguments: [false, true])
    func receivedConsumptionBlocksPublicationWithoutOpeningInboxAndSurvivesRestart(delayedKey: Bool) async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let local = try sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: []))
        try await stageProfile(profile, in: f.journal)
        try await queueSession(local, in: f.journal)
        try await f.startReady()
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let key = delayedKey ? try CloudCryptoFixture.key() : f.key
        let remote = try f.record(.session(sessionDocument(profile: profile,
            payload: .desktop(signIn: next, consumed: [CloudSessionPayload.fingerprint(old.refreshToken)]))), key: key)
        defer { remote.lease.release() }
        await f.driver.emit(.fetched(records: [remote.record], deletions: []))
        if delayedKey {
            #expect(try await f.journal.load().canPublishSession(local))
            await f.keys.deliver(key)
            try await f.transport.syncNow()
        }
        #expect(await f.driver.batch() == nil)
        #expect(await f.keys.writers == 0)
        await f.transport.stop()
        let reopened = CloudSyncJournal(root: f.disk.root, owner: CloudCryptoFixture.owner)
        #expect(try await !reopened.load().canPublishSession(local))
        let driver = CloudFakeEngineDriver()
        let restarted = CloudKitAccountSync(journal: reopened, keys: f.keys, assets: f.assets, makeDriver: { driver })
        try await restarted.start(owner: CloudCryptoFixture.owner, epoch: UUID())
        await driver.emit(.zoneFetched(error: nil))
        #expect(await driver.batch() == nil)
        await restarted.stop()
    }

    @Test func receivedConsumptionDuringWriterKeyAwaitBlocksPreparedRecord() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        try await stageProfile(profile, in: f.journal)
        try await queueSession(sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: [])), in: f.journal)
        try await f.startReady()
        await f.keys.holdWriter()
        let sending = Task { await f.driver.batch() }
        await f.keys.waitForWriter()
        // A second transport instance shares the durable owner partition. The
        // first instance's serial callback queue is intentionally held by batch.
        let receiver = CloudFakeEngineDriver()
        let transport = CloudKitAccountSync(journal: f.journal, keys: f.keys, assets: f.assets, makeDriver: { receiver })
        try await transport.start(owner: CloudCryptoFixture.owner, epoch: UUID())
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let remote = try f.record(.session(sessionDocument(profile: profile,
            payload: .desktop(signIn: next, consumed: [CloudSessionPayload.fingerprint(old.refreshToken)]))))
        defer { remote.lease.release() }
        await receiver.emit(.fetched(records: [remote.record], deletions: []))
        await f.keys.releaseWriter()
        #expect(await sending.value == nil)
        await transport.stop(); await f.transport.stop()
    }

    @Test(arguments: ["account", "user", "profile", "kind", "invalid", "future", "routing", "missing"])
    func unrelatedOrUnvalidatedConsumptionCannotPoisonPublication(boundary: String) async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let local = try sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: []))
        try await stageProfile(profile, in: f.journal)
        try await queueSession(local, in: f.journal)
        try await f.startReady()
        let next = try CodexSignIn(data: CodexSignInFixture.data(account: boundary == "account" ? "other" : old.identity.accountID,
            user: boundary == "user" ? "other" : old.identity.userID, refresh: UUID().uuidString))
        let consumed = [CloudSessionPayload.fingerprint(old.refreshToken)]
        let payload: CloudSessionPayload = boundary == "kind" ? .openChamber(value: .legacy(try next.openChamberAuth()), consumed: consumed)
            : .desktop(signIn: next, consumed: consumed)
        let valid = try sessionDocument(profile: boundary == "profile" ? CodexSignInFixture.profile() : profile, payload: payload)
        let document = CloudSessionDocument(profileID: valid.profileID, sourceDeviceID: valid.sourceDeviceID, sourceName: valid.sourceName,
            kind: valid.kind, revision: valid.revision, capturedAt: valid.capturedAt,
            payload: boundary == "invalid" ? Data("{\"desktop\":{\"consumed\":[\"\(consumed[0])\"]}}".utf8) : valid.payload)
        let remote = try f.record(.session(document), key: boundary == "missing" ? CloudCryptoFixture.key() : f.key)
        defer { remote.lease.release() }
        if boundary == "future" { remote.record["schemaVersion"] = Int64(99) as CKRecordValue }
        if boundary == "routing" { remote.record["profileID"] = UUID().uuidString.lowercased() as CKRecordValue }
        await f.driver.emit(.fetched(records: [remote.record], deletions: []))
        let batch = try #require(await f.driver.batch())
        #expect(batch.recordsToSave.map(\.recordID.recordName) == [CloudRecordCodec.recordName(for: .session(local))])
        if ["invalid", "future", "routing", "missing"].contains(boundary) {
            #expect(try await CloudSessionInbox(journal: f.journal, keys: f.keys).summaries(for: profile).isEmpty)
        }
        await f.transport.stop()
    }

    @Test func compactedCatalogDuplicatesPreserveTombstonesAndGenerationHistory() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        let original = try #require(try await f.journal.load().profiles[name])
        let old = try f.record(.profile(original))
        let deleted = try f.record(.profile(.init(id: original.id, createdAt: original.createdAt, fields: original.fields,
            tombstone: .init(version: .init(counter: 100, deviceID: UUID()), deletedAt: .now))))
        try await f.startReady()
        await f.driver.emit(.fetched(records: [old.record, deleted.record], deletions: []))
        let order = try #require(try await f.journal.load().transport?.inboxOrder)
        for id in order {
            try await f.journal.transaction { state in
                try state.beginApplying(id, postProjection: .init(profiles: []), documents: state.profiles.mapValues { .profile($0) })
            }
            try await f.journal.transaction { _ = try $0.replay(id, catalog: .trusted(.init(profiles: []))) }
        }
        try f.journal.compactCompletedCatalog()
        let before = try await f.journal.load()
        // Latest duplicate short-circuits; an older compacted ID must merge safely.
        await f.driver.emit(.fetched(records: [deleted.record, old.record], deletions: []))
        try await f.transport.syncNow()
        let after = try await f.journal.load()
        #expect(after.profiles == before.profiles)
        #expect(after.recordGenerations == before.recordGenerations)
        #expect(after.dirtyGenerations == before.dirtyGenerations)
        #expect(after.receivedEnvelopes.count == 1)
        #expect(after.transport?.processedInbox.count == 1)
        #expect(await f.driver.batch() != nil)
        await f.transport.stop()
    }

    @Test func coordinatorPublicationGateAndSessionOptOutBlockRealEncryptedBatchAdmission() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profileName = try await f.localProfile()
        let profile = try #require(try await f.journal.load().profiles[profileName])
        let session = CloudSessionDocument(profileID: profile.id, sourceDeviceID: UUID(), sourceName: "synthetic", kind: .desktop,
            revision: 1, capturedAt: .now, payload: Data([1]))
        let sessionName = CloudRecordCodec.recordName(for: .session(session))
        try await f.journal.transaction { state in
            state.sessions[sessionName] = session
            try state.markDirty(recordName: sessionName, body: .session(session))
            state.transport = .init()
            state.transport?.catalogPublicationPaused = true
        }
        try await f.startReady()
        #expect(await f.driver.batch() == nil)
        #expect(await f.keys.writers == 0)
        try await f.journal.transaction {
            $0.transport?.catalogPublicationPaused = false
            $0.transport?.includeSavedSessions = false
        }
        let batch = try #require(await f.driver.batch())
        #expect(batch.recordsToSave.map(\.recordID.recordName) == [profileName])
        #expect(try await f.journal.load().dirtyGenerations[sessionName] != nil)
        await f.transport.stop()
    }

    @Test func productionPendingAdapterPreservesDeletionPrecedenceAcrossRepeatedReplacements() {
        let id = CloudRecordCodec.recordID("session.synthetic")
        let other = CloudRecordCodec.recordID("profile.synthetic")
        let state = CloudSyntheticPendingState()
        state.add(pendingRecordZoneChanges: [.saveRecord(id), .deleteRecord(id)])
        #expect(state.pendingRecordZoneChanges == [.deleteRecord(id)])
        for desired: [CKSyncEngine.PendingRecordZoneChange] in [[.saveRecord(id), .deleteRecord(id)], [.deleteRecord(id), .saveRecord(id)]] {
            CloudEnginePendingChanges.replace(in: state, with: desired)
            #expect(state.pendingRecordZoneChanges == [.deleteRecord(id)])
        }
        CloudEnginePendingChanges.replace(in: state, with: [.saveRecord(other)])
        #expect(state.pendingRecordZoneChanges == [.saveRecord(other)])
        CloudEnginePendingChanges.replace(in: state, with: [])
        #expect(state.pendingRecordZoneChanges.isEmpty)
    }

    @Test func affirmativeAutomaticAndExplicitFetchEvidenceCanReportSuccessButIsNotReused() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        try await f.startReady()
        await f.driver.emit(.fetchStarted)
        await f.driver.emit(.zoneFetched(error: nil))
        await f.driver.emit(.fetchFinished)
        let automatic = try #require(try await f.journal.load().lastSuccess)
        await f.driver.emit(.fetchStarted)
        await f.driver.emit(.fetchFinished)
        #expect(try await f.journal.load().lastSuccess == automatic)
        try await f.journal.transaction { $0.lastSuccess = .distantPast }
        try await f.transport.syncNow()
        #expect(try await f.journal.load().lastSuccess != .distantPast)
        await f.transport.stop()
    }

    @Test func stopDuringPreviousEngineDrainInvalidatesSuspendedStartIntent() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        try await f.startReady()
        await f.driver.holdCancellation()
        let restarting = Task { try await f.start() }
        await f.driver.waitForCancellation()
        let startingIntent = await f.transport.lifecycleIntent
        let stopping = Task { await f.transport.stop() }
        while await f.transport.lifecycleIntent == startingIntent { await Task.yield() }
        await f.driver.finishCancellation()
        await #expect(throws: CloudTransportError.notStarted) { try await restarting.value }
        await stopping.value
        #expect(await f.driver.starts == 1)
        #expect(await f.driver.batch() == nil)
        #expect(try await f.journal.load().dirtyGenerations[name] != nil)
    }

    @Test func stopDuringDriverStartupDoesNotOpenBatchAdmission() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        await f.driver.holdStartup()
        let starting = Task { try await f.start() }
        await f.driver.waitForStartup()
        let intent = await f.transport.lifecycleIntent
        let stopping = Task { await f.transport.stop() }
        while await f.transport.lifecycleIntent == intent { await Task.yield() }
        await f.driver.emit(.zoneFetched(error: nil))
        #expect(await f.driver.batch() == nil)
        await f.driver.finishStartup()
        await #expect(throws: CloudTransportError.notStarted) { try await starting.value }
        await stopping.value
        #expect(try await f.journal.load().dirtyGenerations[name] != nil)
    }

    @Test func downloadedAssetReadFailureStopsEpochWithoutClassifyingServerRecordAsInvalid() async throws {
        for missingParent in [false, true] {
            let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
            let name = try await f.localProfile()
            try await f.journal.transaction { $0.engineState = Data([11]) }
            let remote = try f.record(.profile(try #require(try await f.journal.load().profiles[name])))
            let originalAsset = remote.record["payload"]
            let missing = missingParent ? f.disk.base.appendingPathComponent("missing-parent/payload.asset") : f.disk.base.appendingPathComponent("missing.asset")
            remote.record["payload"] = CKAsset(fileURL: missing)
            try await f.startReady()
            await f.driver.emit(.fetched(records: [remote.record], deletions: []))
            await f.driver.emit(.state(Data([12])))
            let failed = try await f.journal.load()
            #expect(failed.engineState == Data([11]))
            #expect(failed.receivedEnvelopes.isEmpty)
            #expect(failed.transport?.blockedRecords[name] == nil)
            #expect(await f.driver.batch() == nil)
            await f.transport.stop()
            remote.record["payload"] = originalAsset
            try await f.startReady()
            #expect(await f.driver.loadedState == Data([11]))
            await f.driver.emit(.fetched(records: [remote.record], deletions: []))
            await f.driver.emit(.state(Data([13])))
            #expect(try await f.journal.load().receivedEnvelopes.count == 1)
            #expect(try await f.journal.load().engineState == Data([13]))
            await f.transport.stop()
        }
    }

    @Test func malformedServerRecordRemainsItemSpecificAndDoesNotStopUnrelatedSends() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let invalid = try await f.localProfile(), valid = try await f.localProfile()
        let record = try f.record(.profile(try #require(try await f.journal.load().profiles[invalid])))
        record.record["schemaVersion"] = "bad" as CKRecordValue
        try await f.startReady()
        await f.driver.emit(.fetched(records: [record.record], deletions: []))
        await f.driver.emit(.state(Data([9])))
        #expect(try await f.journal.load().transport?.blockedRecords[invalid] == .invalid)
        #expect(try await f.journal.load().engineState == Data([9]))
        #expect(await f.driver.batch()?.recordsToSave.map(\.recordID.recordName) == [valid])
        await f.transport.stop()
    }

    @Test func automaticDatabaseFetchCompletionWithoutZoneSuccessCannotAdvanceLastSuccess() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        try await f.startReady()
        try await f.journal.transaction { $0.lastSuccess = .distantPast }
        // This is also the SDK event sequence for a database-level failure: there is
        // no per-zone error, and DidFetchChanges exposes no result/error property.
        await f.driver.emit(.fetchStarted)
        await f.driver.emit(.fetchFinished)
        await f.driver.emit(.sendFinished)
        #expect(try await f.journal.load().lastSuccess == .distantPast)
        await f.driver.emit(.accountChanged)
        var events = f.transport.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .accountChanged = event.value { break }
            if case .status(.upToDate) = event.value { Issue.record("Completion alone published success") }
        }
        await f.transport.stop()
    }

    @Test func manualDatabaseFetchErrorAfterDelegateCompletionCannotPublishSuccess() async throws {
        for withZoneSuccess in [false, true] {
            let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
            try await f.startReady()
            try await f.journal.transaction { $0.lastSuccess = .distantPast }
            await f.driver.setFetchInspector { try await f.journal.load().lastSuccess }
            await f.driver.failFetchAfterDelegateCompletion(withZoneSuccess: withZoneSuccess)
            await #expect(throws: CKError.self) { try await f.transport.syncNow() }
            #expect(try await f.journal.load().lastSuccess == .distantPast)
            #expect(await f.driver.lastSuccessBeforeFetchThrow == .distantPast)
            await f.driver.emit(.accountChanged)
            var events = f.transport.events.makeAsyncIterator()
            while let event = await events.next() {
                if case .accountChanged = event.value { break }
                if case .status(.upToDate) = event.value { Issue.record("Failed fetch published success") }
            }
            await f.transport.stop()
        }
    }

    @Test func repeatedPendingRefreshCannotReplaceTombstoneSessionDeleteWithDirtySave() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profileID = UUID()
        let session = CloudSessionDocument(profileID: profileID, sourceDeviceID: UUID(), sourceName: "synthetic", kind: .desktop, revision: 1, capturedAt: .distantPast, payload: Data([1]))
        let name = CloudRecordCodec.recordName(for: .session(session))
        try await f.journal.transaction { state in
            state.sessions[name] = session
            try state.markDirty(recordName: name, body: .session(session))
            let tombstone = CloudProfileDocument(id: profileID, createdAt: .distantPast,
                tombstone: .init(version: .init(counter: 1, deviceID: UUID()), deletedAt: .distantPast))
            state.profiles[CloudJournalState.profileRecordName(profileID)] = tombstone
            state.lamportCounter = 1
            state.transport = .init()
            state.transport?.sessionProfiles[name] = profileID
            state.transport?.acknowledgedTombstones.insert(profileID)
            state.transport?.pendingSessionDeletes.insert(name)
        }
        try await f.startReady()
        for _ in 0..<3 { await f.driver.emit(.fetched(records: [], deletions: [])) }
        #expect(await f.driver.pending == [.deleteRecord(CloudRecordCodec.recordID(name))])
        #expect(await f.driver.lastSubmittedPending == [.deleteRecord(CloudRecordCodec.recordID(name))])
        #expect(await f.driver.batch()?.recordIDsToDelete == [CloudRecordCodec.recordID(name)])
        await f.transport.stop()
    }

    @Test func fetchedSessionAbsenceSettlesDirtyRetryAndBlockedStateWithoutErasingLocalSnapshot() async throws {
        for indexed in [false, true] {
            let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
            let session = CloudSessionDocument(profileID: UUID(), sourceDeviceID: UUID(), sourceName: "synthetic", kind: .desktop, revision: 1, capturedAt: .distantPast, payload: Data([1]))
            let name = CloudRecordCodec.recordName(for: .session(session))
            try await f.journal.transaction { state in
                state.sessions[name] = session
                try state.markDirty(recordName: name, body: .session(session))
                state.transport = .init()
                if indexed {
                    state.transport?.sessionProfiles[name] = session.profileID
                    state.transport?.pendingSessionDeletes.insert(name)
                }
                state.transport?.blockedRecords[name] = .quota
                state.transport?.retryAfter[name] = .distantFuture
            }
            try await f.startReady()
            let before = try await f.journal.load()
            await f.driver.emit(.fetched(records: [], deletions: [CloudRecordCodec.recordID(name)]))
            await f.driver.emit(.fetched(records: [], deletions: [CloudRecordCodec.recordID(name)]))
            let state = try await f.journal.load()
            #expect(state.dirtyGenerations[name] == nil)
            #expect(state.transport?.retryAfter[name] == nil)
            #expect(state.transport?.blockedRecords[name] == nil)
            #expect(state.transport?.pendingSessionDeletes.contains(name) == false)
            #expect(state.transport?.deletedSessions.contains(name) == true)
            #expect(state.sessions[name] == session)
            #expect(state.recordGenerations == before.recordGenerations)
            #expect(state.payloadDigests == before.payloadDigests)
            #expect(await f.driver.pending.isEmpty)
            await f.transport.stop()
        }
    }

    @Test func storageRecoveryRecreatesDriverFromLastDurableStateAfterBackoff() async throws {
        let fault = CloudTransportFault(), sleeper = CloudTransportSleeper()
        let f = try await CloudTransportFixture(io: .init { op, name in try fault.check(op, name) },
            sleep: { seconds in try await sleeper.sleep(seconds) }); defer { f.disk.cleanUp() }
        try await f.journal.transaction { $0.engineState = Data([42]) }
        try await f.startReady()
        fault.enable()
        await f.driver.emit(.state(Data([43])))
        fault.disable()
        // A failed epoch must schedule recovery instead of accepting later cursor events.
        // The status is observable before advancing the controlled recovery clock.
        await f.driver.emit(.state(Data([44])))
        #expect(try await f.journal.load().engineState == Data([42]))
        #expect(await f.transport.recoveryTask != nil)
        if await f.transport.recoveryTask != nil {
            await sleeper.waitForSleep(1)
            await sleeper.wake()
            await f.driver.waitForStarts(2)
            #expect(await f.driver.loadedState == Data([42]))
        }
        await f.transport.stop()
    }

    @Test func activeCatalogApplyDefersNewRemoteMergeUntilReceiptCompletes() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        let profile = try #require(try await f.journal.load().profiles[name])
        let receipt = try await f.journal.receive(recordName: name, ciphertext: Data([1]))
        try await f.journal.transaction { state in
            try state.beginApplying(receipt.id, postProjection: state.committedProjection, documents: [name: .profile(profile)])
        }
        let remote = try f.record(.profile(.init(id: profile.id, createdAt: profile.createdAt,
            fields: .init(notes: .init(value: "after apply", version: .init(counter: 10, deviceID: UUID()))))))
        try await f.startReady()
        await f.driver.emit(.fetched(records: [remote.record], deletions: []))
        #expect(try await f.journal.load().profiles[name]?.fields.notes == nil)
        #expect(await f.driver.batch() == nil)
        _ = try await f.journal.transaction { state in try state.replay(receipt.id, catalog: .trusted(state.committedProjection)) }
        try await f.transport.syncNow()
        #expect(try await f.journal.load().profiles[name]?.fields.notes?.value == "after apply")
        await f.transport.stop()
    }

    @Test func queuedLocalSessionIsRemovedFromPublicationOnlyAfterTombstoneAndDeleteAcknowledgements() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        let profile = try #require(try await f.journal.load().profiles[name])
        let session = CloudSessionDocument(profileID: profile.id, sourceDeviceID: UUID(), sourceName: "synthetic", kind: .desktop, revision: 1, capturedAt: .distantPast, payload: Data([1]))
        let sessionName = CloudRecordCodec.recordName(for: .session(session))
        try await f.journal.transaction { state in
            state.sessions[sessionName] = session
            try state.markDirty(recordName: sessionName, body: .session(session))
            let deleted = CloudProfileDocument(id: profile.id, createdAt: profile.createdAt,
                tombstone: .init(version: .init(counter: 2, deviceID: UUID()), deletedAt: .distantPast))
            state.profiles[name] = deleted; state.lamportCounter = 2
            try state.markDirty(recordName: name, body: .profile(deleted))
        }
        try await f.startReady()
        let first = try #require(await f.driver.batch())
        #expect(first.recordsToSave.map(\.recordID.recordName) == [name])
        #expect(first.recordIDsToDelete.isEmpty)
        await f.driver.emit(.sent(saved: first.recordsToSave, failed: [], deleted: [], failedDeletes: [:]))
        let deletion = try #require(await f.driver.batch())
        #expect(deletion.recordIDsToDelete.map(\.recordName) == [sessionName])
        await f.driver.emit(.sent(saved: [], failed: [], deleted: deletion.recordIDsToDelete, failedDeletes: [:]))
        #expect(try await f.journal.load().dirtyGenerations[sessionName] == nil)
        #expect(try await f.journal.load().sessions[sessionName] == session)
        await f.transport.stop()
    }

    @Test func manualReconciliationDiskFailureClosesEpochBeforeLaterStateUpdate() async throws {
        let fault = CloudTransportFault()
        let f = try await CloudTransportFixture(io: .init { op, name in try fault.check(op, name) }); defer { f.disk.cleanUp() }
        _ = try await f.localProfile()
        try await f.startReady()
        fault.enable()
        await #expect(throws: (any Error).self) { try await f.transport.syncNow() }
        fault.disable()
        await f.driver.emit(.state(Data([12])))
        #expect(try await f.journal.load().engineState == nil)
        #expect(await f.driver.batch() == nil)
        await f.transport.stop()
    }

    @Test func firstMissingZoneStillAllowsExplicitCreation() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        try await f.start()
        await f.driver.emit(.zoneFetched(error: CKError(.zoneNotFound)))
        #expect(try await f.journal.load().transport?.zoneLost != true)
        try await f.transport.createZoneForFirstUse()
        #expect(await f.driver.zoneCreations == 1)
        await f.transport.stop()
    }

    @Test func sessionGenerationReplayDeduplicatesAndRejectsReusedRevisionContent() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let session = CloudSessionDocument(profileID: UUID(), sourceDeviceID: UUID(), sourceName: "synthetic", kind: .desktop, revision: 1, capturedAt: .distantPast, payload: Data([1]))
        let first = try f.record(.session(session)), duplicate = try f.record(.session(session))
        let corrupt = try f.record(.session(.init(profileID: session.profileID, sourceDeviceID: session.sourceDeviceID,
            sourceName: session.sourceName, kind: session.kind, revision: session.revision, capturedAt: session.capturedAt, payload: Data([2]))))
        try await f.start()
        await f.driver.emit(.fetched(records: [first.record, duplicate.record, corrupt.record], deletions: []))
        await f.driver.emit(.zoneFetched(error: nil))
        await f.driver.emit(.fetchFinished)
        await f.transport.stop()
        let state = try await f.journal.load()
        #expect(state.transport?.processedInbox.count == 2)
        #expect(state.sessions.isEmpty)
        #expect(state.lastSuccess == nil)
        #expect(state.receivedEnvelopes.count == 3)
    }

    @Test func expiredChangeTokenRecreatesEngineAndRequiresFullFetchWithoutErasingDirtyTombstone() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        try await f.journal.transaction { state in
            let old = state.profiles[name]!
            let deleted = CloudProfileDocument(id: old.id, createdAt: old.createdAt, fields: old.fields,
                tombstone: .init(version: .init(counter: 2, deviceID: UUID()), deletedAt: .distantPast))
            state.profiles[name] = deleted; state.lamportCounter = 2
            try state.markDirty(recordName: name, body: .profile(deleted))
        }
        try await f.startReady()
        await f.driver.emit(.state(Data([7])))
        let original = try await f.journal.load().sentRevision(for: name)
        await f.driver.emit(.zoneFetched(error: CKError(.changeTokenExpired)))
        await f.driver.waitForStarts(2)
        #expect(await f.driver.loadedState == nil)
        #expect(try await f.journal.load().sentRevision(for: name) == original)
        #expect(try await f.journal.load().profiles[name]?.tombstone != nil)
        #expect(await f.driver.batch() == nil)
        await f.driver.emit(.fetched(records: [], deletions: []))
        #expect(await f.driver.batch() == nil)
        await f.driver.emit(.zoneFetched(error: nil))
        #expect(await f.driver.batch()?.recordsToSave.count == 1)
        await f.transport.stop()
    }

    @Test func accountChangeRejectsLateOwnerEventsAndKeepsDirtyWork() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        try await f.startReady()
        let batch = try #require(await f.driver.batch())
        let callbacks = try #require(await f.driver.callbacks)
        await f.driver.emit(.accountChanged)
        await callbacks.event(.sent(saved: batch.recordsToSave, failed: [], deleted: [], failedDeletes: [:]))
        await callbacks.event(.state(Data([100])))
        #expect(try await f.journal.load().dirtyGenerations[name] != nil)
        #expect(try await f.journal.load().engineState == nil)
        #expect(await f.driver.batch() == nil)
        await f.transport.stop()
    }

    @Test func fetchNetworkFailureNeverBecomesUpToDateAndSuccessClearsGlobalRetry() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        try await f.startReady()
        await f.driver.emit(.zoneFetched(error: CKError(.networkFailure)))
        await f.driver.emit(.fetchFinished)
        #expect(try await f.journal.load().lastSuccess == nil)
        await f.driver.emit(.zoneFetched(error: nil))
        await f.driver.emit(.fetchFinished)
        #expect(try await f.journal.load().lastSuccess != nil)
        await f.transport.stop()
    }

    @Test func futureDecryptedDocumentSchemaQuarantinesWithoutChangingLocalGeneration() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        let original = try #require(try await f.journal.load().profiles[name])
        let record = try f.record(.profile(original))
        let future = CloudRecordBody.profile(.init(schemaVersion: 2, id: original.id, createdAt: original.createdAt))
        let cipher = try CloudPayloadCipher.seal(CloudJournalCoding.encode(future), key: f.key,
            context: .init(owner: CloudCryptoFixture.owner, recordName: name, kind: "profile", schema: 1, keyID: f.key.id))
        let file = try f.assets.stage(cipher)
        record.record["payload"] = CKAsset(fileURL: file)
        try await f.startReady()
        await f.driver.emit(.fetched(records: [record.record], deletions: []))
        #expect(await f.driver.batch() == nil)
        #expect(try await f.journal.load().profiles[name] == original)
        #expect(try await f.journal.load().sentRevision(for: name)?.generation == 1)
        await f.transport.stop()
    }

    @Test func ciphertextAndCursorPersistAcrossRestartBeforeMissingKeyArrives() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile(), key = try CloudCryptoFixture.key()
        let id = try #require(try await f.journal.load().profiles[name]?.id)
        let remote = try f.record(.profile(.init(id: id, createdAt: .distantPast,
            fields: .init(notes: .init(value: "restart note", version: .init(counter: 5, deviceID: UUID()))))), key: key)
        try await f.startReady()
        await f.driver.emit(.fetched(records: [remote.record], deletions: []))
        await f.driver.emit(.state(Data([77])))
        await f.transport.stop()
        await f.keys.deliver(key)
        let driver = CloudFakeEngineDriver()
        let restarted = CloudKitAccountSync(journal: CloudSyncJournal(root: f.disk.root, owner: CloudCryptoFixture.owner), keys: f.keys, assets: f.assets, makeDriver: { driver })
        try await restarted.start(owner: CloudCryptoFixture.owner, epoch: UUID())
        #expect(await driver.loadedState == Data([77]))
        let batch = try #require(await driver.batch())
        guard case .profile(let merged) = try f.codec.decode(f.codec.envelope(from: batch.recordsToSave[0]), owner: CloudCryptoFixture.owner, key: f.key) else { Issue.record("Expected profile"); return }
        #expect(merged.fields.notes?.value == "restart note")
        await restarted.stop()
    }

    @Test func temporaryPerItemFailureRetriesOnlyAfterRetryAfterAndCancellationClosesAdmission() async throws {
        let clock = CloudTransportClock()
        let f = try await CloudTransportFixture(now: { clock.now() }); defer { f.disk.cleanUp() }
        _ = try await f.localProfile()
        try await f.startReady()
        let sent = try #require(await f.driver.batch())
        await f.driver.emit(.sent(saved: [], failed: [.init(record: sent.recordsToSave[0], error: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0]))], deleted: [], failedDeletes: [:]))
        await f.driver.emit(.sendFinished)
        clock.advance(59)
        #expect(await f.driver.batch() == nil)
        clock.advance(1)
        #expect(await f.driver.batch()?.recordsToSave.count == 1)
        await f.transport.stop()
        #expect(await f.driver.batch() == nil)
    }

    @Test func boundedRetryWakeDoesNotContactEngineBeforeServerDeadline() async throws {
        let clock = CloudTransportClock(), sleeper = CloudTransportSleeper()
        let f = try await CloudTransportFixture(now: { clock.now() }, sleep: { seconds in try await sleeper.sleep(seconds) }); defer { f.disk.cleanUp() }
        try await f.startReady()
        await f.driver.emit(.zoneFetched(error: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 3600.0])))
        await sleeper.waitForSleep(1)
        clock.advance(300)
        await sleeper.wake()
        await sleeper.waitForSleep(2)
        #expect(await f.driver.fetchCalls == 0)
        #expect(await f.driver.sendCalls == 0)
        await f.transport.stop()
    }

    @Test func fetchedPhysicalProfileDeletionBlocksReseedingButDoesNotInventTombstone() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        try await f.startReady()
        await f.driver.emit(.fetched(records: [], deletions: [CloudRecordCodec.recordID(name)]))
        #expect(await f.driver.batch() == nil)
        #expect(try await f.journal.load().profiles[name]?.tombstone == nil)
        #expect(try await f.journal.load().dirtyGenerations[name] != nil)
        await f.transport.stop()
    }

    @Test func constructionIsInertAndTransportEventsCarryTheActiveOwnerAndEpoch() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        #expect(await f.driver.callbacks == nil)
        #expect(await f.keys.lookups == 0)
        #expect(await f.keys.writers == 0)
        let epoch = UUID()
        var iterator = f.transport.events.makeAsyncIterator()
        try await f.transport.start(owner: CloudCryptoFixture.owner, epoch: epoch)
        let event = try #require(await iterator.next())
        #expect(event.owner == CloudCryptoFixture.owner)
        #expect(event.epoch == epoch)
        guard case .status(.syncing) = event.value else { Issue.record("Expected syncing event"); return }
        await f.transport.stop()
    }

    @Test func stateUpdateCannotOvertakeSuspendedInboxMerge() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        try await f.start()
        let record = try f.record(.profile(.init(id: UUID(), createdAt: .distantPast)))
        await f.keys.holdLookups()
        let fetch = Task { await f.driver.emit(.fetched(records: [record.record], deletions: [])) }
        await f.keys.waitForLookup()
        let checkpoint = Task { await f.driver.emit(.state(Data([12]))) }
        #expect(try await f.journal.load().engineState == nil)
        #expect(try await f.journal.load().receivedEnvelopes.count == 1)
        await f.keys.releaseLookups()
        await fetch.value; await checkpoint.value
        #expect(try await f.journal.load().engineState == Data([12]))
        #expect(try await f.journal.load().transport?.processedInbox.count == 1)
        await f.transport.stop()
    }

    @Test func cancellationDuringMissingKeyLookupPreventsMergeAfterDrain() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        try await f.start()
        let id = UUID()
        let record = try f.record(.profile(.init(id: id, createdAt: .distantPast)))
        await f.keys.holdLookups()
        let fetch = Task { await f.driver.emit(.fetched(records: [record.record], deletions: [])) }
        await f.keys.waitForLookup()
        await f.driver.holdCancellation()
        let stopping = Task { await f.transport.stop() }
        await f.driver.waitForCancellation()
        await f.keys.releaseLookups()
        await fetch.value
        #expect(try await f.journal.load().profiles["profile." + id.uuidString.lowercased()] == nil)
        #expect(try await f.journal.load().receivedEnvelopes.count == 1)
        await f.driver.finishCancellation()
        await stopping.value
    }

    @Test func initialFetchNeedsWholeZoneCompletionAndSendsHonorScope() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let first = try await f.localProfile(), second = try await f.localProfile()
        try await f.start()
        #expect(await f.driver.batch() == nil)
        await f.driver.emit(.fetched(records: [], deletions: []))
        #expect(await f.driver.batch() == nil)
        await f.driver.emit(.zoneFetched(error: nil))
        let batch = try #require(await f.driver.batch(scope: .recordIDs([CloudRecordCodec.recordID(first)])))
        #expect(batch.recordsToSave.map(\.recordID.recordName) == [first])
        #expect(!batch.recordsToSave.contains { $0.recordID.recordName == second })
        await f.transport.stop()
    }

    @Test func exactSentGenerationCannotAcknowledgeNewerEditAndLeaseLivesUntilOutcome() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        try await f.startReady()
        let batch = try #require(await f.driver.batch())
        let record = try #require(batch.recordsToSave.first)
        let url = try #require((record["payload"] as? CKAsset)?.fileURL)
        #expect(throws: CloudAssetError.inUse) { try f.assets.remove(url) }
        let old = try await f.journal.load().sentRevision(for: name)
        try await f.edit(name, label: "newer edit")
        await f.driver.emit(.sent(saved: [record], failed: [], deleted: [], failedDeletes: [:]))
        let state = try await f.journal.load()
        #expect(state.sentRevision(for: name)?.generation == (old?.generation ?? 0) + 1)
        #expect(state.profiles[name]?.fields.label?.value == "newer edit")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await f.transport.stop()
    }

    @Test func missingKeyQuarantinesOnlyItsRecordAndDeliveryReplaysDurableInbox() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let blocked = try await f.localProfile(), unrelated = try await f.localProfile()
        let remoteKey = try CloudCryptoFixture.key()
        let remote = try f.record(.profile(.init(id: try #require(try await f.journal.load().profiles[blocked]?.id), createdAt: .distantPast,
            fields: .init(notes: .init(value: "remote note", version: .init(counter: 40, deviceID: UUID()))))), key: remoteKey)
        try await f.start()
        await f.driver.emit(.fetched(records: [remote.record], deletions: []))
        await f.driver.emit(.state(Data([4])))
        await f.driver.emit(.zoneFetched(error: nil))
        let first = try #require(await f.driver.batch())
        #expect(first.recordsToSave.map(\.recordID.recordName) == [unrelated])
        #expect(try await f.journal.load().engineState == Data([4]))
        #expect(try await f.journal.load().receivedEnvelopes.count == 1)
        await f.keys.deliver(remoteKey)
        try await f.transport.syncNow()
        let next = try #require(await f.driver.batch())
        #expect(next.recordsToSave.map(\.recordID.recordName) == [blocked])
        let body = try f.codec.decode(f.codec.envelope(from: next.recordsToSave[0]), owner: CloudCryptoFixture.owner, key: f.key)
        guard case .profile(let merged) = body else { Issue.record("Expected profile"); return }
        #expect(merged.fields.notes?.value == "remote note")
        #expect(merged.fields.label?.value == "local")
        await f.transport.stop()
    }

    @Test func conflictMergesLatestDirtyDocumentAndReusesServerSystemFields() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        try await f.startReady()
        let batch = try #require(await f.driver.batch())
        try await f.edit(name, label: "edited during send")
        let id = try #require(try await f.journal.load().profiles[name]?.id)
        let remote = try f.record(.profile(.init(id: id, createdAt: .distantPast,
            fields: .init(notes: .init(value: "server note", version: .init(counter: 30, deviceID: UUID()))))))
        // Synthetic server metadata, never a live record. An archive from a fresh record
        // would lose this tag, so the assertion detects a retry built without server fields.
        let server = try CloudSyntheticServerRecord.withChangeTag(remote.record)
        #expect(server.recordChangeTag == "CPBEncryptedRecordV1")
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        await f.driver.emit(.sent(saved: [], failed: [.init(record: batch.recordsToSave[0], error: error)], deleted: [], failedDeletes: [:]))
        let retry = try #require(await f.driver.batch())
        let decoded = try f.codec.decode(f.codec.envelope(from: retry.recordsToSave[0]), owner: CloudCryptoFixture.owner, key: f.key)
        guard case .profile(let merged) = decoded else { Issue.record("Expected profile"); return }
        #expect(merged.fields.label?.value == "edited during send")
        #expect(merged.fields.notes?.value == "server note")
        #expect(retry.recordsToSave[0].recordChangeTag == "CPBEncryptedRecordV1")
        #expect(try CloudRecordCodec.systemFields(of: retry.recordsToSave[0]) == CloudRecordCodec.systemFields(of: server))
        #expect(try await f.journal.load().receivedEnvelopes.count == 1)
        await f.transport.stop()
    }

    @Test func mixedOutcomesRetainFailuresAndNeverClaimSuccess() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        var names: [String] = []
        for _ in 0..<4 { names.append(try await f.localProfile()) }
        try await f.startReady()
        let batch = try #require(await f.driver.batch())
        let records = batch.recordsToSave.sorted { $0.recordID.recordName < $1.recordID.recordName }
        let failures: [CloudEngineRecordFailure] = [
            .init(record: records[1], error: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 3600.0])),
            .init(record: records[2], error: CKError(.quotaExceeded)),
            .init(record: records[3], error: CKError(.permissionFailure))]
        await f.driver.emit(.sent(saved: [records[0]], failed: failures, deleted: [], failedDeletes: [:]))
        await f.driver.emit(.sendFinished)
        let state = try await f.journal.load()
        #expect(state.dirtyGenerations.count == 3)
        #expect(state.dirtyGenerations[records[0].recordID.recordName] == nil)
        #expect(state.lastSuccess == nil)
        #expect(await f.driver.batch() == nil)
        await f.transport.stop()
    }

    @Test func futureSchemaAndDuplicateFetchRemainDurableWithoutReplacingLocalEdits() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        let body = CloudRecordBody.profile(try #require(try await f.journal.load().profiles[name]))
        let record = try f.record(body)
        record.record["schemaVersion"] = Int64(99) as CKRecordValue
        try await f.start()
        await f.driver.emit(.fetched(records: [record.record, record.record], deletions: []))
        await f.driver.emit(.zoneFetched(error: nil))
        await f.driver.emit(.state(Data([8])))
        #expect(try await f.journal.load().receivedEnvelopes.count == 1)
        #expect(try await f.journal.load().sentRevision(for: name)?.generation == 1)
        #expect(await f.driver.batch() == nil)
        await f.transport.stop()
        try await f.start()
        #expect(await f.driver.batch() == nil)
        #expect(try await f.journal.load().engineState == Data([8]))
        await f.transport.stop()
    }

    @Test func diskFailureBeforeCursorInvalidatesEpochAndRestartUsesLastDurableState() async throws {
        let fault = CloudTransportFault()
        let f = try await CloudTransportFixture(io: .init { op, name in try fault.check(op, name) }); defer { f.disk.cleanUp() }
        try await f.journal.transaction { $0.engineState = Data([1]) }
        try await f.start()
        let record = try f.record(.profile(.init(id: UUID(), createdAt: .distantPast)))
        fault.enable()
        await f.driver.emit(.fetched(records: [record.record], deletions: []))
        await f.driver.emit(.state(Data([2])))
        fault.disable()
        #expect(try await f.journal.load().engineState == Data([1]))
        #expect(await f.driver.batch() == nil)
        await f.transport.stop()
        try await f.start()
        #expect(await f.driver.loadedState == Data([1]))
        await f.transport.stop()
    }

    @Test func cancellationRetainsAssetsUntilDrainAndOldCallbacksCannotAcknowledge() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        try await f.startReady()
        let batch = try #require(await f.driver.batch())
        let record = batch.recordsToSave[0]
        let url = try #require((record["payload"] as? CKAsset)?.fileURL)
        let callbacks = try #require(await f.driver.callbacks)
        await f.driver.holdCancellation()
        let stopping = Task { await f.transport.stop() }
        await f.driver.waitForCancellation()
        #expect(throws: CloudAssetError.inUse) { try f.assets.remove(url) }
        await callbacks.event(.sent(saved: [record], failed: [], deleted: [], failedDeletes: [:]))
        #expect(try await f.journal.load().dirtyGenerations[name] != nil)
        await f.driver.finishCancellation()
        await stopping.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await f.startReady()
        await callbacks.event(.state(Data([99])))
        #expect(try await f.journal.load().engineState != Data([99]))
        await f.transport.stop()
    }

    @Test func zoneLossPausesAcrossRestartAndFirstCreationRequiresExplicitRequest() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        _ = try await f.localProfile()
        try await f.start()
        #expect(await f.driver.zoneCreations == 0)
        try await f.transport.createZoneForFirstUse()
        #expect(await f.driver.zoneCreations == 1)
        await f.driver.emit(.zoneSaved(error: nil))
        await f.driver.emit(.zoneFetched(error: nil))
        await f.driver.emit(.zoneLost)
        #expect(await f.driver.batch() == nil)
        await f.transport.stop()
        await #expect(throws: CloudTransportError.zoneLost) { try await f.start() }
        #expect(await f.driver.zoneCreations == 1)
        await f.transport.stop()
    }

    @Test func tombstoneAcknowledgementPrecedesSessionDeletionIncludingLateArrivals() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let name = try await f.localProfile()
        let profile = try #require(try await f.journal.load().profiles[name])
        let session = CloudSessionDocument(profileID: profile.id, sourceDeviceID: UUID(), sourceName: "synthetic", kind: .desktop, revision: 1, capturedAt: .distantPast, payload: Data([9]))
        let remote = try f.record(.session(session))
        try await f.journal.transaction { state in
            let deleted = CloudProfileDocument(id: profile.id, createdAt: profile.createdAt, fields: profile.fields,
                tombstone: .init(version: .init(counter: 2, deviceID: UUID()), deletedAt: .now))
            state.profiles[name] = deleted; state.lamportCounter = 2
            try state.markDirty(recordName: name, body: .profile(deleted))
        }
        try await f.startReady()
        await f.driver.emit(.fetched(records: [remote.record], deletions: []))
        let first = try #require(await f.driver.batch())
        #expect(first.recordIDsToDelete.isEmpty)
        #expect(first.recordsToSave.count == 1)
        await f.driver.emit(.sent(saved: first.recordsToSave, failed: [], deleted: [], failedDeletes: [:]))
        let cleanup = try #require(await f.driver.batch())
        #expect(cleanup.recordIDsToDelete.map(\.recordName) == [CloudRecordCodec.recordName(for: .session(session))])
        await f.driver.emit(.sent(saved: [], failed: [], deleted: [], failedDeletes: [cleanup.recordIDsToDelete[0]: CKError(.quotaExceeded)]))
        await f.driver.emit(.sendFinished)
        #expect(await f.driver.batch() == nil)
        #expect(try await f.journal.load().transport?.pendingSessionDeletes.count == 1)
        try await f.transport.syncNow()
        let cleanupRetry = try #require(await f.driver.batch())
        #expect(cleanupRetry.recordIDsToDelete == cleanup.recordIDsToDelete)
        await f.driver.emit(.sent(saved: [], failed: [], deleted: cleanup.recordIDsToDelete, failedDeletes: [:]))
        await f.driver.emit(.sendFinished)
        let late = try f.record(.session(.init(profileID: profile.id, sourceDeviceID: UUID(), sourceName: "late", kind: .browser, revision: 1, capturedAt: .now, payload: Data([8]))))
        await f.driver.emit(.fetched(records: [late.record], deletions: []))
        let lateCleanup = try #require(await f.driver.batch())
        #expect(lateCleanup.recordsToSave.isEmpty)
        #expect(lateCleanup.recordIDsToDelete.map(\.recordName) == [late.record.recordID.recordName])
        await f.transport.stop()
    }

    @Test func retriedSessionDeletionClearsRetryStateWhenServerReportsAlreadyAbsent() async throws {
        let clock = CloudTransportClock()
        let f = try await CloudTransportFixture(now: { clock.now() }); defer { f.disk.cleanUp() }
        let profileID = UUID()
        let tombstone = try f.record(.profile(.init(id: profileID, createdAt: .distantPast,
            tombstone: .init(version: .init(counter: 1, deviceID: UUID()), deletedAt: .distantPast))))
        let session = try f.record(.session(.init(profileID: profileID, sourceDeviceID: UUID(), sourceName: "synthetic", kind: .desktop, revision: 1, capturedAt: .distantPast, payload: Data([1]))))
        try await f.startReady()
        await f.driver.emit(.fetched(records: [tombstone.record, session.record], deletions: []))
        let batch = try #require(await f.driver.batch())
        let id = try #require(batch.recordIDsToDelete.first)
        await f.driver.emit(.sent(saved: [], failed: [], deleted: [], failedDeletes: [id: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])]))
        await f.driver.emit(.sendFinished)
        clock.advance(30)
        #expect(await f.driver.batch()?.recordIDsToDelete == [id])
        await f.driver.emit(.sent(saved: [], failed: [], deleted: [], failedDeletes: [id: CKError(.unknownItem)]))
        await f.driver.emit(.sendFinished)
        #expect(try await f.journal.load().transport?.pendingSessionDeletes.isEmpty == true)
        #expect(try await f.journal.load().transport?.retryAfter.isEmpty == true)
        await f.transport.stop()
    }
}

actor CloudFakeEngineDriver: CloudEngineDriving {
    var callbacks: CloudEngineCallbacks?
    var loadedState: Data?
    private let pendingState = CloudSyntheticPendingState()
    var pending: [CKSyncEngine.PendingRecordZoneChange] { pendingState.pendingRecordZoneChanges }
    var lastSubmittedPending: [CKSyncEngine.PendingRecordZoneChange] = []
    var inspectFetchCompletion: (@Sendable () async throws -> Date?)?
    var lastSuccessBeforeFetchThrow: Date?
    private var failedFetchZoneSuccess: Bool?
    var zoneCreations = 0
    var fetchCalls = 0, sendCalls = 0
    private(set) var starts = 0
    private var startWaiter: (Int, CheckedContinuation<Void, Never>)?
    private var held = false
    private var cancellation: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var operations = CloudEngineOperationDrain()
    private var holdStart = false
    private var startup: CheckedContinuation<Void, Never>?
    private var startupWaiter: CheckedContinuation<Void, Never>?
    func start(owner: CloudOwner, state: Data?, callbacks: CloudEngineCallbacks) async throws {
        self.loadedState = state; self.callbacks = callbacks; starts += 1
        operations = CloudEngineOperationDrain()
        if let waiter = startWaiter, starts >= waiter.0 { startWaiter = nil; waiter.1.resume() }
        if holdStart {
            await withCheckedContinuation { startup = $0; startupWaiter?.resume(); startupWaiter = nil }
        }
    }
    func holdStartup() { holdStart = true }
    func waitForStartup() async { if startup == nil { await withCheckedContinuation { startupWaiter = $0 } } }
    func finishStartup() { holdStart = false; startup?.resume(); startup = nil }
    func waitForStarts(_ count: Int) async {
        if starts < count { await withCheckedContinuation { startWaiter = (count, $0) } }
    }
    func setPending(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        lastSubmittedPending = changes
        CloudEnginePendingChanges.replace(in: pendingState, with: changes)
    }
    func createZone() { zoneCreations += 1 }
    func failFetchAfterDelegateCompletion(withZoneSuccess: Bool) { failedFetchZoneSuccess = withZoneSuccess }
    func setFetchInspector(_ inspect: @escaping @Sendable () async throws -> Date?) { inspectFetchCompletion = inspect }
    func fetchChanges() async throws {
        fetchCalls += 1
        if let withZoneSuccess = failedFetchZoneSuccess {
            await callbacks?.event(.fetchStarted)
            if withZoneSuccess { await callbacks?.event(.zoneFetched(error: nil)) }
            await callbacks?.event(.fetchFinished)
            lastSuccessBeforeFetchThrow = try await inspectFetchCompletion?()
            throw CKError(.networkFailure)
        }
    }
    func sendChanges() async throws { sendCalls += 1 }
    func cancelOperations() async {
        guard held else { return }
        await operations.close()
        await withCheckedContinuation { continuation in
            cancellation = continuation; cancellationWaiter?.resume(); cancellationWaiter = nil
        }
        await operations.waitForCompletion()
    }
    func holdCancellation() async { held = true; await operations.beginOperation() }
    func waitForCancellation() async { if cancellation == nil { await withCheckedContinuation { cancellationWaiter = $0 } } }
    func finishCancellation() async {
        held = false; cancellation?.resume(); cancellation = nil
        await operations.endOperation()
    }
    func emit(_ event: CloudEngineEvent) async { await callbacks?.event(event) }
    func batch(scope: CKSyncEngine.SendChangesOptions.Scope = .all) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await callbacks?.nextBatch(scope, pending)
    }
}

/// Models the documented State.add last-operation-wins contract, not a second copy of
/// the production reconciliation algorithm. No CKContainer or CKSyncEngine is constructed.
final class CloudSyntheticPendingState: CloudEnginePendingState, @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [CKSyncEngine.PendingRecordZoneChange] = []
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { lock.withLock { changes } }
    func remove(pendingRecordZoneChanges removals: [CKSyncEngine.PendingRecordZoneChange]) {
        lock.withLock { changes.removeAll { removals.contains($0) } }
    }
    func add(pendingRecordZoneChanges additions: [CKSyncEngine.PendingRecordZoneChange]) {
        lock.withLock {
            for addition in additions {
                changes.removeAll { Self.id($0) == Self.id(addition) }
                changes.append(addition)
            }
        }
    }
    private static func id(_ change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): id
        @unknown default: nil
        }
    }
}

actor CloudTransportKeys: CloudKeyStoring {
    let writer: CloudEncryptionKey
    var delivered: [UUID: CloudEncryptionKey]
    var lookups = 0, writers = 0
    private var hold = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var writerHeld = false
    private var writerContinuation: CheckedContinuation<Void, Never>?
    private var writerWaiter: CheckedContinuation<Void, Never>?
    init(_ key: CloudEncryptionKey) { writer = key; delivered = [key.id: key] }
    func writerKey(owner: CloudOwner, deviceID: UUID) async throws -> CloudEncryptionKey {
        writers += 1
        if writerHeld { await withCheckedContinuation { writerContinuation = $0; writerWaiter?.resume(); writerWaiter = nil } }
        return writer
    }
    func holdWriter() { writerHeld = true }
    func waitForWriter() async { if writerContinuation == nil { await withCheckedContinuation { writerWaiter = $0 } } }
    func releaseWriter() { writerHeld = false; writerContinuation?.resume(); writerContinuation = nil }
    func key(id: UUID, owner: CloudOwner) async throws -> CloudEncryptionKey? {
        lookups += 1
        if hold { await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil } }
        return delivered[id]
    }
    func holdLookups() { hold = true }
    func waitForLookup() async { if held == nil { await withCheckedContinuation { waiter = $0 } } }
    func releaseLookups() { hold = false; held?.resume(); held = nil }
    func deliver(_ key: CloudEncryptionKey) { delivered[key.id] = key }
}

func queueSession(_ document: CloudSessionDocument, in journal: CloudSyncJournal) async throws {
    try await journal.transaction {
        let name = CloudRecordCodec.recordName(for: .session(document))
        $0.sessions[name] = document
        try $0.markDirty(recordName: name, body: .session(document))
    }
}

struct CloudTransportFixture {
    let disk: CloudCryptoFixture
    let key: CloudEncryptionKey
    let keys: CloudTransportKeys
    let journal: CloudSyncJournal
    let assets: CloudAssetStore
    let codec: CloudRecordCodec
    let driver: CloudFakeEngineDriver
    let transport: CloudKitAccountSync
    init(io: CloudJournalIO = .init(), now: @escaping @Sendable () -> Date = { .now },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws {
        disk = try CloudCryptoFixture(); key = try CloudCryptoFixture.key(); keys = CloudTransportKeys(key)
        journal = CloudSyncJournal(root: disk.root, owner: CloudCryptoFixture.owner, io: io)
        assets = CloudAssetStore(root: disk.base.appendingPathComponent("staging")); codec = CloudRecordCodec(assets: assets)
        driver = CloudFakeEngineDriver()
        let driver = driver
        transport = CloudKitAccountSync(journal: journal, keys: keys, assets: assets, makeDriver: { driver }, now: now, sleep: sleep)
    }
    func start() async throws { try await transport.start(owner: CloudCryptoFixture.owner, epoch: UUID()) }
    func startReady() async throws { try await start(); await driver.emit(.zoneFetched(error: nil)) }
    func localProfile() async throws -> String {
        let id = UUID(), device = UUID()
        return try await journal.transaction { state in
            let body = CloudProfileDocument(id: id, createdAt: .distantPast, fields: .init(label: .init(value: "local", version: .init(counter: 1, deviceID: device))))
            let name = "profile." + id.uuidString.lowercased()
            state.profiles[name] = body; state.lamportCounter = max(1, state.lamportCounter)
            try state.markDirty(recordName: name, body: .profile(body)); return name
        }
    }
    func edit(_ name: String, label: String) async throws {
        try await journal.transaction { state in
            let original = state.profiles[name]!
            var fields = original.fields
            state.lamportCounter += 1
            fields.label = .init(value: label, version: .init(counter: state.lamportCounter, deviceID: UUID()))
            let body = CloudProfileDocument(id: original.id, createdAt: original.createdAt, fields: fields)
            state.profiles[name] = body; try state.markDirty(recordName: name, body: .profile(body))
        }
    }
    func record(_ body: CloudRecordBody, key: CloudEncryptionKey? = nil) throws -> CloudEncodedRecord {
        try codec.encode(body, owner: CloudCryptoFixture.owner, key: key ?? self.key)
    }
}

final class CloudTransportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

actor CloudTransportSleeper {
    private var requests = 0
    private var pending: CheckedContinuation<Void, any Error>?
    private var waiter: (Int, CheckedContinuation<Void, Never>)?
    func sleep(_ seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation; requests += 1
                if let waiter, requests >= waiter.0 { self.waiter = nil; waiter.1.resume() }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func waitForSleep(_ count: Int) async { if requests < count { await withCheckedContinuation { waiter = (count, $0) } } }
    func wake() { pending?.resume(); pending = nil }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil }
}

enum CloudSyntheticServerRecord {
    /// CKRecord's KVC setter treats system keys as user fields and raises an exception.
    /// This test-only fixture uses the installed SDK's archive keys to give a synthetic
    /// record a nonnil ETag. Production uses only encodeSystemFields / CKRecord(coder:).
    static func withChangeTag(_ record: CKRecord) throws -> CKRecord {
        let bytes = try CloudRecordCodec.systemFields(of: record)
        var archive = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        var top = try #require(archive["$top"] as? [String: Any])
        let typeReference = try #require(top["RecordType"])
        top["ETag"] = typeReference
        archive["$top"] = top
        let modified = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: modified)
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        let restored = try #require(CKRecord(coder: decoder))
        for key in record.allKeys() { restored[key] = record[key] }
        return restored
    }
}

final class CloudTransportFault: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    func enable() { lock.withLock { enabled = true } }
    func disable() { lock.withLock { enabled = false } }
    func check(_ operation: CloudJournalIO.Operation, _ name: String) throws {
        if lock.withLock({ enabled }), operation == .fileSync, name == "journal.json" { throw POSIXError(.ENOSPC) }
    }
}
