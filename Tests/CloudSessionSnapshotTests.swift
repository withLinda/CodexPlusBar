import Foundation
import Testing
@testable import CodexPlusBar

@MainActor struct CloudSessionSnapshotTests {
    @Test func repeatedCapturesExceedHistoricalJournalCapacityButKeepCurrentBodySmall() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let admission = try #require(f.coordinator.sessionAdmission(for: f.profile.id))
        let source = try f.device
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        var cumulativeBytes = 0
        for revision in 1...48 {
            var object = try #require(JSONSerialization.jsonObject(with: CodexSignInFixture.data(refresh: UUID().uuidString)) as? [String: Any])
            object["syntheticPadding"] = String(repeating: "x", count: 900 * 1_024)
            let signIn = try CodexSignIn(data: JSONSerialization.data(withJSONObject: object))
            let payload = CloudSessionPayload.desktop(signIn: signIn,
                consumed: revision == 1 ? [CloudSessionPayload.fingerprint(old.refreshToken)] : [])
            let document = try sessionDocument(profile: f.profile, payload: payload, source: source, revision: UInt64(revision))
            cumulativeBytes += try CloudJournalCoding.encode(document).count
            try f.coordinator.commitCapturedSession(document, admission: admission)
            try #require(try f.journal.catalogState().sessions.count == 1)
        }
        #expect(cumulativeBytes > CloudSyncJournal.maximumJournalBytes)
        await f.coordinator.stop()
        let restarted = CloudSyncJournal(root: f.root.appendingPathComponent("cloud"), owner: f.owner)
        let state = try await restarted.load()
        #expect(state.sessions.count == 1)
        #expect(state.sessions.values.first?.revision == 48)
        #expect(try CloudJournalCoding.encode(state).count < 12 * 1_024 * 1_024)
        let stale = try sessionDocument(profile: f.profile, payload: .desktop(signIn: old, consumed: []), source: UUID())
        // Publication approval is independent of the evidence being checked here.
        var approved = state; approved.transport?.validatedSessionRecords = nil
        #expect(!approved.canPublishSession(stale))
        await f.coordinator.start()
        let resumed = try #require(f.coordinator.sessionAdmission(for: f.profile.id))
        #expect(throws: CloudSyncModelError.conflictingVersion) {
            try f.coordinator.commitCapturedSession(sessionDocument(profile: f.profile,
                payload: .desktop(signIn: old, consumed: []), source: source, revision: 1), admission: resumed)
        }
        await f.coordinator.stop()
    }

    @Test func compactedCaptureKeepsExactInFlightBodyAndOldAckCannotClearNewSend() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let admission = try #require(f.coordinator.sessionAdmission(for: f.profile.id)), source = try f.device
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let first = try sessionDocument(profile: f.profile, payload: .desktop(signIn: old, consumed: []), source: source)
        let second = try sessionDocument(profile: f.profile, payload: .desktop(signIn: next, consumed: []), source: source, revision: 2)
        try f.coordinator.commitCapturedSession(first, admission: admission)
        let driver = CloudFakeEngineDriver(), keys = CloudTransportKeys(try CloudCryptoFixture.key())
        let assets = CloudAssetStore(root: f.root.appendingPathComponent("staging"))
        let transport = CloudKitAccountSync(journal: f.journal, keys: keys, assets: assets, makeDriver: { driver })
        try await transport.start(owner: f.owner, epoch: UUID())
        await driver.emit(.zoneFetched(error: nil))
        let batch = try #require(await driver.batch())
        let sent = try #require(batch.recordsToSave.first { $0.recordID.recordName == CloudRecordCodec.recordName(for: .session(first)) })
        let codec = CloudRecordCodec(assets: assets)
        try f.coordinator.commitCapturedSession(second, admission: admission)
        #expect(try f.journal.catalogState().sessions.count == 1)
        let encrypted = try codec.envelope(from: sent)
        #expect(try codec.decode(encrypted, owner: f.owner, key: keys.writer) == .session(first))
        await driver.emit(.sent(saved: batch.recordsToSave, failed: [], deleted: [], failedDeletes: [:]))
        let name = CloudRecordCodec.recordName(for: .session(second))
        #expect(try f.journal.catalogState().dirtyGenerations[name] != nil)
        await driver.emit(.sendFinished)
        let nextBatch = try #require(await driver.batch())
        #expect(nextBatch.recordsToSave.map(\.recordID.recordName) == [name])
        await transport.stop(); await f.coordinator.stop()
        #expect(try await CloudSyncJournal(root: f.root.appendingPathComponent("cloud"), owner: f.owner).load().sessions.values.first == second)
    }

    @Test(arguments: [false, true])
    func inboxRejectsCandidateWhenRemoteEvidenceArrivesDuringKeyLookup(otherSource: Bool) async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile(), source = UUID()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let first = try f.record(.session(sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: []), source: source)))
        defer { first.lease.release() }
        try await stageProfile(profile, in: f.journal)
        try await f.startReady()
        await f.driver.emit(.fetched(records: [first.record], deletions: []))
        // Only the inbox reader is suspended; transport can authenticate the arrival.
        let readerKeys = CloudTransportKeys(f.key)
        let inbox = CloudSessionInbox(journal: f.journal, keys: readerKeys)
        await readerKeys.holdLookups()
        let lookup = Task { try? await inbox.candidate(recordName: first.record.recordID.recordName, for: profile) }
        await readerKeys.waitForLookup()
        let newer = try f.record(.session(sessionDocument(profile: profile,
            payload: .desktop(signIn: next, consumed: otherSource ? [CloudSessionPayload.fingerprint(old.refreshToken)] : []),
            source: otherSource ? UUID() : source, revision: otherSource ? 1 : 2)))
        defer { newer.lease.release() }
        await f.driver.emit(.fetched(records: [newer.record], deletions: []))
        await readerKeys.releaseLookups()
        #expect(await lookup.value == nil)
        #expect(try await inbox.summaries(for: profile).map(\.recordName) == [newer.record.recordID.recordName])
        await f.transport.stop()
    }

    @Test func coordinatorRejectsCandidateAfterInboxChangesAndFreshReadSucceeds() async throws {
        let keys = CloudTransportKeys(try CloudCryptoFixture.key())
        let f = try SessionFixture(inboxKeys: keys); defer { f.clean() }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let codec = CloudRecordCodec(assets: .init(root: f.root.appendingPathComponent("staging")))
        let source = UUID()
        let first = try sessionDocument(profile: f.profile,
            payload: .desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: []), source: source)
        let record = try codec.encode(.session(first), owner: f.owner, key: keys.writer)
        defer { record.lease.release() }
        let envelope = try codec.envelope(from: record.record)
        try await f.journal.receive(id: envelope.id, recordName: envelope.recordName,
            metadata: CloudJournalCoding.encode(envelope.routing), ciphertext: envelope.ciphertext)
        await keys.holdLookups()
        let lookup = Task { try? await f.coordinator.sessionCandidate(recordName: envelope.recordName, for: f.profile.id) }
        await keys.waitForLookup()
        let second = try sessionDocument(profile: f.profile,
            payload: .desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: []), source: source, revision: 2)
        let newer = try codec.encode(.session(second), owner: f.owner, key: keys.writer)
        defer { newer.lease.release() }
        let arrival = try codec.envelope(from: newer.record)
        try await f.journal.receive(id: arrival.id, recordName: arrival.recordName,
            metadata: CloudJournalCoding.encode(arrival.routing), ciphertext: arrival.ciphertext)
        await keys.releaseLookups()
        #expect(await lookup.value == nil)
        let candidate = try await f.coordinator.sessionCandidate(recordName: arrival.recordName, for: f.profile.id)
        #expect(candidate.summary.revision == 2)
        #expect(candidate.validationStamp != nil)
        await f.coordinator.stop()
    }

    @Test func postDurableSaveAutomaticallyPublishesResolvedGeneration() async throws {
        let native = try NativeSwitchFixture(); defer { native.cleanUp() }
        try CodexSignInFixture.data(refresh: UUID().uuidString).write(to: native.authURL)
        let identity = try await native.service.saveCurrent(for: native.profile)
        let capture = CloudSessionSnapshotService(providers: [{ profile in try await native.service.captureSavedSession(for: profile) }], revision: { 0 })
        let f = try SessionFixture(snapshots: capture); defer { f.clean() }
        var row = f.profile; row.codexSignIn = identity
        try f.store.saveProfiles([row])
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let previous = try #require(try f.journal.catalogState().sessions.values.first)
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: identity.accountID, user: identity.userID, refresh: UUID().uuidString))
        try fresh.data.write(to: native.authURL)
        let wake = SessionCaptureBarrier()
        f.transport.didSync = { _ = await wake.wait() }
        _ = try await native.service.saveCurrent(for: row)
        await wake.entered()
        let latest = try #require(try f.journal.catalogState().sessions.values.max { $0.revision < $1.revision })
        #expect(latest.revision == previous.revision + 1)
        let payload = try JSONDecoder().decode(CloudSessionPayload.self, from: latest.payload)
        if case .desktop(let signIn, _) = payload { #expect(signIn == fresh) }
        else { Issue.record("Expected latest saved generation") }
        wake.release()
        await f.coordinator.stop()
    }

    @Test func freshRunDoesNotPublishRetainedSessionUntilStoresAreReconciled() async throws {
        let payload = try CloudSessionPayload.desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: [])
        let provider = SessionProviderState(payload)
        let f = try SessionFixture(snapshots: .init(providers: [{ _ in try provider.read() }], revision: { 0 }))
        defer { f.clean() }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let document = try #require(try f.journal.catalogState().sessions.values.first)
        #expect(try f.journal.catalogState().canPublishSession(document))
        await f.coordinator.setEnabled(false)
        provider.fail = true
        await f.coordinator.setEnabled(true)
        #expect(try f.journal.catalogState().sessions.values.contains(document))
        #expect(try !f.journal.catalogState().canPublishSession(document))
        provider.fail = false
        #expect(await f.coordinator.captureSavedSessions())
        await f.coordinator.syncNow()
        #expect(try f.journal.catalogState().canPublishSession(document))
        #expect(try f.journal.catalogState().sessions.count == 1)
        await f.coordinator.stop()
    }

    @Test func transportDoesNotPublishKnownConsumedGenerationBeforeRecapture() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let document = try sessionDocument(profile: profile, payload: .desktop(signIn: old, consumed: []))
        try await stageProfile(profile, in: f.journal)
        try await f.journal.transaction {
            let name = CloudRecordCodec.recordName(for: .session(document))
            $0.sessions[name] = document
            try $0.markDirty(recordName: name, body: .session(document))
        }
        try await f.startReady()
        CloudSavedSessionChange.consumed(CloudSessionPayload.fingerprint(old.refreshToken), kind: .desktop)
        #expect(await f.driver.batch() == nil)
        #expect(await f.keys.writers == 0)
        #expect(try await f.journal.load().sessions.count == 1)
        await f.transport.stop()
    }

    @Test func malformedNewestRevisionDoesNotExposeReplayedOlderSource() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile(), source = UUID()
        let payload = try CloudSessionPayload.desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: [])
        try await stageProfile(profile, in: f.journal)
        try await f.startReady()
        for revision: UInt64 in [1, 2] {
            let document = CloudSessionDocument(profileID: profile.id, sourceDeviceID: source, sourceName: "Synthetic Mac",
                kind: .desktop, revision: revision, capturedAt: .now, payload: revision == 1 ? try payload.encoded() : Data([0]))
            let record = try f.codec.encode(.session(document), owner: CloudCryptoFixture.owner, key: f.key)
            await f.driver.emit(.fetched(records: [record.record], deletions: [])); record.lease.release()
        }
        #expect(try await CloudSessionInbox(journal: f.journal, keys: f.keys).summaries(for: profile).isEmpty)
        await f.transport.stop()
    }

    @Test func manualSyncReconcilesAndFailedCaptureRetainsPriorSnapshotAndProfileSync() async throws {
        let signIn = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let provider = SessionProviderState(.desktop(signIn: signIn, consumed: []))
        let capture = CloudSessionSnapshotService(providers: [{ _ in try provider.read() }], revision: { 0 })
        let f = try SessionFixture(snapshots: capture); defer { f.clean() }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        #expect(try f.journal.catalogState().sessions.count == 1)
        let original = try f.journal.catalogState().sessions
        await f.coordinator.syncNow(); await f.coordinator.syncNow()
        #expect(try f.journal.catalogState().sessions == original)
        provider.fail = true
        var draft = PlusProfileDetailsDraft(profile: f.profile); draft.notes = "metadata continues"
        #expect(f.profiles.updateDetails(for: f.profile.id, draft: draft))
        await f.coordinator.syncNow()
        #expect(try f.journal.catalogState().profiles[CloudJournalState.profileRecordName(f.profile.id)]?.fields.notes?.value == "metadata continues")
        #expect(try f.journal.catalogState().sessions == original)
        provider.fail = false; provider.current = nil
        await f.coordinator.syncNow()
        #expect(try f.journal.catalogState().sessions == original)
        await f.coordinator.stop()
    }

    @Test(arguments: ["delete", "disable", "sessions", "backup", "owner", "rotation"])
    func delayedCaptureCannotOutliveAdmission(action: String) async throws {
        let barrier = SessionCaptureBarrier()
        let payload = try CloudSessionPayload.desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: [])
        let f = try SessionFixture(snapshots: .init(providers: [{ _ in
            guard await barrier.wait() else { return nil }; return payload
        }]))
        defer { f.clean() }
        await f.coordinator.start()
        let enabling = Task { await f.coordinator.setEnabled(true) }
        await barrier.entered()
        switch action {
        case "delete": try f.store.saveProfiles([])
        case "disable": await f.coordinator.setEnabled(false)
        case "sessions": await f.coordinator.setIncludesSessions(false)
        case "backup": try await f.coordinator.pauseForTransfer(restoring: false)
        case "owner":
            f.currentOwner = .init(container: f.owner.container, environment: .development, userRecordName: "different-owner")
            await f.coordinator.setEnabled(false)
        default: CloudSavedSessionChange.committed()
        }
        barrier.release()
        await enabling.value
        #expect(try f.journal.catalogState().sessions.isEmpty)
        await f.coordinator.stop()
    }

    @Test func malformedIdentityKindAndKnownConsumedPayloadAreRejected() throws {
        let signIn = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        #expect(throws: CloudSessionError.consumedGeneration) {
            try CloudSessionPayload.desktop(signIn: signIn, consumed: [CloudSessionPayload.fingerprint(signIn.refreshToken)]).validated()
        }
        let cookie = BackupCookie(name: "__Secure-next-auth.session-token", value: "synthetic", domain: "chatgpt.com", path: "/", secure: true,
            httpOnly: true, expires: nil, sameSite: nil)
        #expect(throws: CloudSessionError.invalidPayload) {
            try CloudSessionPayload.browser(cookies: [cookie], identity: .init(accountID: "different", userID: "user"), accessToken: signIn.accessToken).validated()
        }
        var value = OpenCodeCredentialValue.legacy(try signIn.openChamberAuth())
        value.fields["nativeBinding"] = .string("must-never-travel")
        #expect(throws: CloudSessionError.invalidPayload) { try CloudSessionPayload.openChamber(value: value, consumed: []).validated() }
    }

    @Test func explicitAdoptionProvenanceSuppressesUnchangedCapture() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let payload = try CloudSessionPayload.desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: [])
        let document = try sessionDocument(profile: f.profile, payload: payload)
        let admission = try #require(f.coordinator.sessionAdmission(for: f.profile.id))
        let candidate = CloudSessionCandidate(summary: .init(recordName: CloudRecordCodec.recordName(for: .session(document)),
            profileID: document.profileID, sourceDeviceID: document.sourceDeviceID, sourceName: document.sourceName,
            kind: .desktop, revision: 1, capturedAt: document.capturedAt, identity: try payload.identity), payload: payload)
        try f.coordinator.recordAdoptedSession(candidate, admission: admission)
        try f.coordinator.commitCapturedSession(sessionDocument(profile: f.profile, payload: payload, source: f.device), admission: admission)
        #expect(try f.journal.catalogState().sessions.isEmpty)
        await f.coordinator.stop()
    }
    @Test func unchangedManualCaptureDoesNotCreateAnotherSourceRevision() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let admission = try #require(f.coordinator.sessionAdmission(for: f.profile.id))
        let bytes = try CloudSessionPayload.desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: []).encoded()
        for revision: UInt64 in [1, 2] {
            let document = CloudSessionDocument(profileID: f.profile.id, sourceDeviceID: try f.device,
                sourceName: "Synthetic Mac", kind: .desktop, revision: revision,
                capturedAt: Date(timeIntervalSince1970: Double(revision)), payload: bytes)
            try f.coordinator.commitCapturedSession(document, admission: admission)
        }
        #expect(try f.journal.catalogState().sessions.count == 1)
        await f.coordinator.stop()
    }

    @Test func persistedConsumedGenerationResolvesWithoutLiveReadOrRefresh() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: true))
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: "synthetic-next"))
        let vault = CodexSignInVault(homeDirectory: home)
        try vault.save(old); try vault.saveRefreshed(next, replacing: old)
        // Reproduce an interrupted main-snapshot write with consumed bytes still on disk.
        try old.data.write(to: vault.url(for: old.identity))
        var profile = CodexSignInFixture.profile(); profile.codexSignIn = old.identity
        let service = CodexAccountSwitchService(homeDirectory: home, resolveStore: { throw CodexSignInError.unsupportedConfiguration })
        let captured = try #require(try await service.captureSavedSession(for: profile))
        #expect(captured == .desktop(signIn: next, consumed: [CloudSessionPayload.fingerprint(old.refreshToken)]))
        #expect(try Data(contentsOf: vault.url(for: old.identity)) == old.data)
    }

    @Test func nativeCaptureHasRecoveryButNoBindingOrNativeWrites() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString, expired: true)).openChamberAuth()
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: "next-native")).openChamberAuth()
        let store = OpenCodeSignInSnapshotStore(homeDirectory: home)
        let identity = try old.identity()
        try store.saveValue(.legacy(old), identity: identity)
        try store.saveBinding(id: "local-native-id", identity: identity)
        try store.saveRefreshed(next, replacing: old)
        var profile = CodexSignInFixture.profile(); profile.openCodeOpenAIAccount = identity
        let service = OpenCodeOpenAIAuthService(homeDirectory: home, resolveRuntime: { throw OpenCodeOpenAIAuthError.runtimeUnavailable },
            operationGate: .init(), selector: SelectorControlClient(homeDirectory: home, connectionRefused: { true }))
        let payload = try #require(try await service.captureSavedSession(for: profile))
        if case .openChamber(let value, let consumed) = payload {
            #expect(try value.auth() == next)
            #expect(consumed.count == 1)
            #expect(!String(decoding: try payload.encoded(), as: UTF8.self).contains("local-native-id"))
        } else { Issue.record("Expected OpenChamber capture") }
        #expect(try store.binding(identity: identity) == "local-native-id")
    }

    @Test func backgroundCaptureDoesNotPauseActiveExpirySelector() async throws {
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        let auth = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)).openChamberAuth()
        let identity = try auth.identity()
        let snapshots = OpenCodeSignInSnapshotStore(homeDirectory: home)
        try snapshots.saveValue(.legacy(auth), identity: identity)
        try snapshots.saveBinding(id: "unchanged-native-selection", identity: identity)
        var profile = CodexSignInFixture.profile(); profile.openCodeOpenAIAccount = identity
        let selector = MaintenanceTestControl(state: .auto)
        let gate = OpenCodeOperationGate()
        let selected = try nativeCredential("destination", active: true)
        let native = SyncTestClient([selected])
        let runtime = SessionRuntimeProbe(.init(authURL: home.appendingPathComponent("auth.json"), credentials: native))
        let service = OpenCodeOpenAIAuthService(homeDirectory: home,
            resolveRuntime: { await runtime.resolve() }, operationGate: gate, selector: selector)
        let before = try snapshots.loadNativeValue(identity: identity)
        let captured = try #require(try await service.captureSavedSession(for: profile))
        #expect(captured == .openChamber(value: .legacy(auth), consumed: []))
        #expect(await selector.state == .auto)
        #expect(await selector.events.isEmpty)
        #expect(try snapshots.binding(identity: identity) == "unchanged-native-selection")
        #expect(try snapshots.loadNativeValue(identity: identity) == before)
        let barrier = SyncBarrier()
        let writer = Task { try await gate.withOperation { await barrier.wait() } }
        await barrier.started()
        await #expect(throws: OpenCodeOpenAIAuthError.busy) { try await service.captureSavedSession(for: profile) }
        await barrier.release(); try await writer.value
        #expect(try await service.captureSavedSession(for: profile) == captured)
        #expect(await selector.events.isEmpty)
        #expect(await runtime.calls == 0)
        #expect(await native.operations.isEmpty)
        #expect(await native.inventory().openAI.first(where: \.active) == selected)
    }

    @Test func oneFailedProviderDoesNotLoseOtherKindsAndInactiveProviderIsInert() async throws {
        let payload = try CloudSessionPayload.desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: [])
        var calls = 0
        let capture = CloudSessionSnapshotService(providers: [{ _ in throw CloudSessionError.unavailable }, { _ in calls += 1; return payload }])
        var profile = CodexSignInFixture.profile()
        #expect(try await capture.capture(for: profile) == [payload])
        profile.provider = .init(rawValue: "inactive-future")
        #expect(try await capture.capture(for: profile).isEmpty)
        #expect(calls == 1)
    }

    @Test func delayedKeyAndReceiptBeforeProfileNeverWriteLiveStores() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let otherKey = try CloudCryptoFixture.key()
        let inbox = CloudSessionInbox(journal: f.journal, keys: f.keys)
        var profile = CodexSignInFixture.profile()
        let payload = try CloudSessionPayload.desktop(signIn: CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString)), consumed: [])
        let document = try sessionDocument(profile: profile, payload: payload)
        let encoded = try f.codec.encode(.session(document), owner: CloudCryptoFixture.owner, key: otherKey)
        defer { encoded.lease.release() }
        let home = f.disk.base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let live = home.appendingPathComponent("auth.json"), binding = home.appendingPathComponent("binding.json")
        let originalLiveBytes = Data("synthetic-live".utf8), originalBinding = Data("synthetic-binding".utf8)
        try originalLiveBytes.write(to: live); try originalBinding.write(to: binding)
        try await f.startReady()
        await f.driver.emit(.fetched(records: [encoded.record], deletions: []))
        #expect(try await inbox.summaries(for: profile).isEmpty)
        try await stageProfile(profile, in: f.journal)
        #expect(try await inbox.summaries(for: profile).isEmpty)
        await f.keys.deliver(otherKey)
        try await f.transport.syncNow()
        let summaries = try await inbox.summaries(for: profile)
        #expect(summaries.count == 1)
        #expect(summaries.first?.identity == (try payload.identity))
        // A new remote profile has no native identity, and no observation is used as proof.
        #expect(profile.codexSignIn == nil && profile.openCodeOpenAIAccount == nil)
        profile.codexSignIn = .init(accountID: "wrong", userID: "user", email: "studio@example.com")
        #expect(try await inbox.summaries(for: profile).isEmpty)
        let destinationLiveBytes = try Data(contentsOf: live), destinationBinding = try Data(contentsOf: binding)
        #expect(destinationLiveBytes == originalLiveBytes)
        #expect(destinationBinding == originalBinding)
        #expect(try await f.journal.load().sessions.isEmpty)
        #expect(try await f.journal.load().dirtyGenerations.isEmpty)
        await f.transport.stop()
    }

    @Test func sourceReplayConsumedEvidenceTombstoneAndSessionOptOut() async throws {
        let f = try await CloudTransportFixture(); defer { f.disk.cleanUp() }
        let profile = CodexSignInFixture.profile(), source = UUID()
        let old = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: "rotated"))
        let oldPayload = CloudSessionPayload.desktop(signIn: old, consumed: [])
        let nextPayload = CloudSessionPayload.desktop(signIn: next, consumed: [CloudSessionPayload.fingerprint(old.refreshToken)])
        try await stageProfile(profile, in: f.journal)
        try await f.startReady()
        for (revision, device, payload) in [(UInt64(2), source, nextPayload), (1, source, oldPayload), (1, UUID(), oldPayload)] {
            let document = try sessionDocument(profile: profile, payload: payload, source: device, revision: revision)
            let record = try f.codec.encode(.session(document), owner: CloudCryptoFixture.owner, key: f.key)
            await f.driver.emit(.fetched(records: [record.record], deletions: [])); record.lease.release()
        }
        let inbox = CloudSessionInbox(journal: f.journal, keys: f.keys)
        #expect(try await inbox.summaries(for: profile).map(\.revision) == [2])
        try await f.journal.transaction { $0.transport?.includeSavedSessions = false }
        #expect(try await inbox.summaries(for: profile).isEmpty)
        try await f.journal.transaction { $0.transport?.includeSavedSessions = true }
        var inactive = profile; inactive.provider = .init(rawValue: "inactive")
        #expect(try await inbox.summaries(for: inactive).isEmpty)
        try await stageProfile(profile, in: f.journal, deleted: true)
        #expect(try await inbox.summaries(for: profile).isEmpty)
        await f.transport.stop()
    }
}

func sessionDocument(profile: PlusProfile, payload: CloudSessionPayload, source: UUID = UUID(), revision: UInt64 = 1) throws -> CloudSessionDocument {
    .init(profileID: profile.id, sourceDeviceID: source, sourceName: "Synthetic Mac", kind: payload.kind,
        revision: revision, capturedAt: Date(timeIntervalSince1970: 100), payload: try payload.encoded())
}

func stageProfile(_ profile: PlusProfile, in journal: CloudSyncJournal, deleted: Bool = false) async throws {
    try await journal.transaction {
        let version = CloudVersion(counter: 1, deviceID: UUID())
        $0.profiles[CloudJournalState.profileRecordName(profile.id)] = .init(id: profile.id, createdAt: profile.createdAt,
            fields: .init(provider: .init(value: profile.provider.rawValue, version: version)),
            tombstone: deleted ? .init(version: version, deletedAt: .now) : nil)
        $0.lamportCounter = 1
    }
}

@MainActor private final class SessionFixture {
    let root: URL
    let profile: PlusProfile
    var device: UUID { get throws { try #require(try preferences.read()?.deviceID) } }
    let store: ProfileCatalogStore
    let journal: CloudSyncJournal
    let preferences: CloudSyncPreferencesStore
    let snapshots: CloudSessionSnapshotService?
    let inboxKeys: (any CloudKeyStoring)?
    let profiles: PlusProfileController
    let transport = SessionTransport()
    let defaults: UserDefaults
    let suite = "CloudSessionTests.\(UUID())"
    let owner = CloudOwner(container: "iCloud.com.linda.CodexPlusBar", environment: .development, userRecordName: "synthetic-session-owner")
    var currentOwner: CloudOwner?
    lazy var coordinator = CloudSyncCoordinator(profiles: profiles, preferences: preferences,
        availability: { .development }, identity: { [self] _ in currentOwner ?? owner }, snapshots: snapshots,
        makeSessionInbox: { [self] journal in .init(journal: journal, keys: inboxKeys ?? CloudKeyStore(journal: journal)) },
        makeTransport: { [self] journal in transport.journal = journal; return transport })
    init(snapshots: CloudSessionSnapshotService? = nil, inboxKeys: (any CloudKeyStoring)? = nil) throws {
        self.inboxKeys = inboxKeys
        self.snapshots = snapshots ?? .init(providers: [], revision: { 0 })
        root = try CodexSignInFixture.directory()
        profile = CodexSignInFixture.profile()
        store = .init(fileURL: root.appendingPathComponent("accounts/profiles.json"))
        try store.saveProfiles([profile])
        journal = .init(root: root.appendingPathComponent("cloud"), owner: owner)
        preferences = .init(root: root.appendingPathComponent("cloud"))
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: OpenChamberSyncPreference.enabledKey)
        profiles = .init(catalogStore: store, dataService: SessionDataService(),
            accountSwitchService: SessionDesktop(), syncDefaults: defaults, autoStart: false)
    }
    func clean() {
        profiles.stopBackgroundTasks(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class SessionCaptureBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async -> Bool {
        guard !released else { return false }
        await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
        return true
    }
    func entered() async { if continuation == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor private final class SessionProviderState {
    var current: CloudSessionPayload?
    var fail = false
    init(_ current: CloudSessionPayload?) { self.current = current }
    func read() throws -> CloudSessionPayload? {
        if fail { throw CloudSessionError.unavailable }
        return current
    }
}

private actor SessionRuntimeProbe {
    private let runtime: OpenCodeLocalRuntime
    private(set) var calls = 0
    init(_ runtime: OpenCodeLocalRuntime) { self.runtime = runtime }
    func resolve() -> OpenCodeLocalRuntime { calls += 1; return runtime }
}

private struct SessionDesktop: CodexAccountSwitchServing {
    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity { throw CodexSignInError.missingCredential }
    func switchAndOpen(profile: PlusProfile) async throws {}
}

@MainActor private final class SessionDataService: PlusProfileDataServing {
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult { throw ChatGPTAPIError.unauthorized }
    func openChromeAccountPage(for profile: PlusProfile) async throws {}
    func openChromeSignIn(for profile: PlusProfile) async throws {}
    func openChromePasskeySetup(for profile: PlusProfile) async throws {}
    func syncChromeSession(for profile: PlusProfile) async throws {}
    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool { false }
    func closeChromeSignIn(for profile: PlusProfile) async {}
    func clearSession(for profile: PlusProfile) async throws {}
    func removeProfileData(for profile: PlusProfile) async throws {}
}

@MainActor private final class SessionTransport: CloudSyncTransport {
    nonisolated let events = AsyncStream<CloudTransportEvent> { _ in }
    var journal: CloudSyncJournal!
    var didSync: (@MainActor () async -> Void)?
    func start(owner: CloudOwner, epoch: UUID) async throws {}
    func syncNow() async throws {
        try await journal.transaction {
            if $0.transport == nil { $0.transport = .init() }
            $0.transport?.initialized = true
        }
        let action = didSync; didSync = nil
        await action?()
    }
    func stop() async {}
}
