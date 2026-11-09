import Foundation
import Security
import Testing
@testable import CodexPlusBar

struct CloudKeyStoreTests {
    @Test func populatedSchemaOneWithoutWriterReferencesAddsKeyAndPreservesOrdinaryTransactions() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let owner = CloudCryptoFixture.owner
        let journal = CloudSyncJournal(root: f.root, owner: owner)
        let device = UUID(), id = UUID()
        try await journal.transaction { state in
            let document = CloudProfileDocument(id: id, createdAt: .distantPast)
            let name = CloudJournalState.profileRecordName(id)
            state.profiles[name] = document
            try state.markDirty(recordName: name, body: .profile(document))
            state.engineState = Data([1, 2, 3])
        }
        let inbox = try await journal.receive(recordName: "synthetic", metadata: Data([4]), ciphertext: Data([5, 6]))
        let before = try await journal.load()
        let path = CloudSyncPaths(root: f.root).partition(for: owner).appendingPathComponent("journal.json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(object["writerKeyIDs"] == nil)
        let security = CloudFakeSecurity()
        let key = try await CloudKeyStore(journal: journal, security: security).writerKey(owner: owner, deviceID: device)
        try await journal.transaction { $0.lastSuccess = .distantPast }
        let reopened = try await CloudSyncJournal(root: f.root, owner: owner).load()
        #expect(reopened.writerKeyIDs?[device] == key.id)
        #expect(reopened.dirtyGenerations == before.dirtyGenerations)
        #expect(reopened.payloadDigests == before.payloadDigests)
        #expect(reopened.profiles == before.profiles)
        #expect(reopened.receivedEnvelopes[inbox.id] == inbox)
        #expect(reopened.receipts == before.receipts)
        #expect(reopened.engineState == before.engineState)
        #expect(try await journal.ciphertext(for: inbox.id) == Data([5, 6]))
        #expect(try await CloudKeyStore(journal: journal, security: security).writerKey(owner: owner, deviceID: device) == key)
    }

    @Test func securityQueriesAreAppScopedSynchronizableAndNeverTouchNativeCredentials() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let security = CloudFakeSecurity()
        let journal = CloudSyncJournal(root: f.root, owner: CloudCryptoFixture.owner)
        let store = CloudKeyStore(journal: journal, security: security)
        let device = UUID()
        let key = try await store.writerKey(owner: CloudCryptoFixture.owner, deviceID: device)
        #expect(key.bytes.count == 32)
        #expect(try await store.key(id: key.id, owner: CloudCryptoFixture.owner) == key)
        security.inspect { reads, additions in
            #expect(!reads.isEmpty)
            #expect(additions.count == 1)
            for query in reads + additions {
                #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
                #expect(query[kSecAttrService as String] as? String == "com.linda.CodexPlusBar.CloudSync.Keys.v1")
                #expect(query[kSecAttrAccessGroup as String] as? String == "2Z8N5KTWQZ.com.linda.CodexPlusBar")
                #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
                #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
                let account = query[kSecAttrAccount as String] as? String
                #expect(account == CloudSyncPaths.ownerDigest(CloudCryptoFixture.owner) + "." + key.id.uuidString.lowercased())
                #expect(account?.contains(CloudCryptoFixture.owner.userRecordName) == false)
            }
            #expect(additions.first?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
            #expect(reads.allSatisfy { $0[kSecReturnData as String] as? Bool == true })
        }
        let reopened = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: CloudCryptoFixture.owner), security: security)
        #expect(try await reopened.writerKey(owner: CloudCryptoFixture.owner, deviceID: device) == key)
        #expect(try await journal.load().writerKeyIDs?[device] == key.id)
    }

    @Test func concurrentDevicesHaveDistinctKeysAndSameDeviceSetupConverges() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let security = CloudFakeSecurity()
        let owner = CloudCryptoFixture.owner
        let deviceA = UUID(), deviceB = UUID()
        let results = try await withThrowingTaskGroup(of: (UUID, CloudEncryptionKey).self) { group in
            for device in [deviceA, deviceB, deviceA, deviceB] {
                group.addTask {
                    let store = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: owner), security: security)
                    return (device, try await store.writerKey(owner: owner, deviceID: device))
                }
            }
            var values: [(UUID, CloudEncryptionKey)] = []
            for try await value in group { values.append(value) }
            return values
        }
        let keysA = results.filter { $0.0 == deviceA }.map(\.1)
        let keysB = results.filter { $0.0 == deviceB }.map(\.1)
        #expect(keysA.count == 2 && keysA[0] == keysA[1])
        #expect(keysB.count == 2 && keysB[0] == keysB[1])
        #expect(keysA[0].id != keysB[0].id)
        #expect(keysA[0].bytes != keysB[0].bytes)
        security.inspect { _, additions in #expect(additions.count == 2) }
    }

    @Test func missingRemoteAndExistingWriterKeysWaitWithoutReplacement() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let security = CloudFakeSecurity()
        let owner = CloudCryptoFixture.owner
        let journal = CloudSyncJournal(root: f.root, owner: owner)
        let store = CloudKeyStore(journal: journal, security: security)
        #expect(try await store.key(id: UUID(), owner: owner) == nil)
        security.inspect { _, additions in #expect(additions.isEmpty) }
        let device = UUID()
        let key = try await store.writerKey(owner: owner, deviceID: device)
        security.eraseItems()
        let reopened = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: owner), security: security)
        await #expect(throws: CloudKeyStoreError.waitingForKey(key.id)) { try await reopened.writerKey(owner: owner, deviceID: device) }
        #expect(try await journal.load().writerKeyIDs?[device] == key.id)
        security.inspect { _, additions in #expect(additions.count == 1) }
    }

    @Test func lockedAndFailedSecurityReadsAreNotMissingKeys() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let owner = CloudCryptoFixture.owner
        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
            let security = CloudFakeSecurity(readStatus: status)
            let store = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: owner), security: security)
            await #expect(throws: CloudKeyStoreError.unavailable(status)) { try await store.key(id: UUID(), owner: owner) }
        }
        let security = CloudFakeSecurity(readStatus: errSecMissingEntitlement)
        let store = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: owner), security: security)
        await #expect(throws: CloudKeyStoreError.securityFailure(errSecMissingEntitlement)) { try await store.key(id: UUID(), owner: owner) }
    }

    @Test func ownersEnvironmentsAndCanonicalUnicodeScopeExactKeyLookup() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let security = CloudFakeSecurity()
        let owner = CloudOwner(container: "container", environment: .development, userRecordName: "é")
        let store = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: owner), security: security)
        let key = try await store.writerKey(owner: owner, deviceID: UUID())
        let equivalent = CloudOwner(container: "container", environment: .development, userRecordName: "e\u{301}")
        #expect(try await store.key(id: key.id, owner: equivalent) == key)
        for other in [CloudOwner(container: "other", environment: .development, userRecordName: "é"),
                      CloudOwner(container: "container", environment: .production, userRecordName: "é"),
                      CloudOwner(container: "container", environment: .development, userRecordName: "other")] {
            #expect(try await store.key(id: key.id, owner: other) == nil)
            await #expect(throws: CloudJournalError.ownerMismatch) { try await store.writerKey(owner: other, deviceID: UUID()) }
        }
        security.inspect { _, additions in #expect(additions.count == 1) }
    }

    @Test func duplicateInsertReadsAndValidatesTheWinningExactItem() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let winningBytes = try CloudCryptoFixture.key().bytes
        let security = CloudFakeSecurity(duplicateBytes: winningBytes)
        let owner = CloudCryptoFixture.owner
        let store = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: owner), security: security)
        let key = try await store.writerKey(owner: owner, deviceID: UUID())
        #expect(key.bytes == winningBytes)
        #expect(try await store.key(id: key.id, owner: owner) == key)
        security.inspect { reads, additions in
            #expect(reads.last?[kSecAttrAccount as String] as? String == additions.last?[kSecAttrAccount as String] as? String)
        }
        let malformed = CloudFakeSecurity(duplicateBytes: Data([1]))
        let second = CloudKeyStore(journal: CloudSyncJournal(root: f.root, owner: owner), security: malformed)
        await #expect(throws: CloudPayloadError.invalidKey) { try await second.writerKey(owner: owner, deviceID: UUID()) }
    }

    @Test func journalFailureNeverReturnsAnUncommittedWriterAndUncertainCommitRecovers() async throws {
        for operation: CloudJournalIO.Operation in [.fileSync, .directorySync] {
            let f = try CloudCryptoFixture(); defer { f.cleanUp() }
            let security = CloudFakeSecurity()
            let owner = CloudCryptoFixture.owner
            let device = UUID()
            let failingJournal = CloudSyncJournal(root: f.root, owner: owner, io: .init { event, name in
                if event == operation, name == "journal.json" { throw POSIXError(.ENOSPC) }
            })
            let failing = CloudKeyStore(journal: failingJournal, security: security)
            await #expect(throws: (any Error).self) { try await failing.writerKey(owner: owner, deviceID: device) }
            let journal = CloudSyncJournal(root: f.root, owner: owner)
            let visible = try await journal.load().writerKeyIDs?[device]
            if operation == .directorySync { #expect(visible != nil) }
            else { #expect(visible == nil) }
            let recovered = try await CloudKeyStore(journal: journal, security: security).writerKey(owner: owner, deviceID: device)
            if let visible { #expect(recovered.id == visible) }
            #expect(try await journal.load().writerKeyIDs?[device] == recovered.id)
            security.inspect { _, additions in #expect(additions.count == (operation == .directorySync ? 1 : 2)) }
        }
    }

    @Test func keyWriteFailureLeavesNoReferenceAndCommittedReferencesAreImmutable() async throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let owner = CloudCryptoFixture.owner
        let journal = CloudSyncJournal(root: f.root, owner: owner)
        let device = UUID()
        let failed = CloudKeyStore(journal: journal, security: CloudFakeSecurity(addStatus: errSecInteractionNotAllowed))
        await #expect(throws: CloudKeyStoreError.unavailable(errSecInteractionNotAllowed)) { try await failed.writerKey(owner: owner, deviceID: device) }
        #expect(try await journal.load().writerKeyIDs?[device] == nil)
        let store = CloudKeyStore(journal: journal, security: CloudFakeSecurity())
        let key = try await store.writerKey(owner: owner, deviceID: device)
        await #expect(throws: CloudJournalError.invalidTransition) {
            try await journal.transaction { $0.writerKeyIDs = nil }
        }
        await #expect(throws: CloudJournalError.invalidTransition) {
            try await journal.transaction { $0.writerKeyIDs?[device] = UUID() }
        }
        #expect(try await journal.load().writerKeyIDs?[device] == key.id)
    }
}

/// Only this adapter replaces Security. Real cipher, journal, locks and disk writes run in tests.
private final class CloudFakeSecurity: CloudSecurityAdapting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var reads: [[String: Any]] = []
    private var additions: [[String: Any]] = []
    private let readStatus: OSStatus?
    private let addStatus: OSStatus?
    private let duplicateBytes: Data?

    init(readStatus: OSStatus? = nil, addStatus: OSStatus? = nil, duplicateBytes: Data? = nil) {
        self.readStatus = readStatus
        self.addStatus = addStatus
        self.duplicateBytes = duplicateBytes
    }

    func copyMatching(_ query: [String: Any]) -> CloudSecurityResult {
        lock.withLock {
            reads.append(query)
            if let readStatus { return .init(status: readStatus, data: nil) }
            guard let account = query[kSecAttrAccount as String] as? String, let data = items[account] else {
                return .init(status: errSecItemNotFound, data: nil)
            }
            return .init(status: errSecSuccess, data: data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            additions.append(attributes)
            if let addStatus { return addStatus }
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            if let duplicateBytes { items[account] = duplicateBytes; return errSecDuplicateItem }
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = data
            return errSecSuccess
        }
    }

    func eraseItems() { lock.withLock { items.removeAll() } }
    func inspect(_ body: ([[String: Any]], [[String: Any]]) -> Void) { lock.withLock { body(reads, additions) } }
}
