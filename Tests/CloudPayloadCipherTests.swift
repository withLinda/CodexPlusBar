import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CodexPlusBar

struct CloudPayloadCipherTests {
    @Test func generatedPayloadRoundTripsWithFreshNonces() throws {
        let key = try CloudCryptoFixture.key()
        let context = CloudCryptoFixture.context(key.id)
        let payload = Data((0..<8_193).map { _ in UInt8.random(in: .min ... .max) })
        let first = try CloudPayloadCipher.seal(payload, key: key, context: context)
        let second = try CloudPayloadCipher.seal(payload, key: key, context: context)
        #expect(first != second)
        #expect(first.count == payload.count + 28)
        #expect(try CloudPayloadCipher.open(first, key: key, context: context) == payload)
        let empty = try CloudPayloadCipher.seal(Data(), key: key, context: context)
        #expect(try CloudPayloadCipher.open(empty, key: key, context: context).isEmpty)
    }

    @Test func everyContextFieldAndCiphertextByteIsAuthenticated() throws {
        let key = try CloudCryptoFixture.key()
        let context = CloudCryptoFixture.context(key.id)
        let encrypted = try CloudPayloadCipher.seal(Data(UUID().uuidString.utf8), key: key, context: context)
        let owner = CloudCryptoFixture.owner
        let contexts = [
            CloudPayloadContext(owner: .init(container: "other", environment: owner.environment, userRecordName: owner.userRecordName), recordName: "profile.test", kind: "profile", schema: 1, keyID: key.id),
            CloudPayloadContext(owner: .init(container: owner.container, environment: .production, userRecordName: owner.userRecordName), recordName: "profile.test", kind: "profile", schema: 1, keyID: key.id),
            CloudPayloadContext(owner: .init(container: owner.container, environment: owner.environment, userRecordName: "other"), recordName: "profile.test", kind: "profile", schema: 1, keyID: key.id),
            CloudPayloadContext(owner: owner, recordName: "other", kind: "profile", schema: 1, keyID: key.id),
            CloudPayloadContext(owner: owner, recordName: "profile.test", kind: "session", schema: 1, keyID: key.id),
            CloudPayloadContext(owner: owner, recordName: "profile.test", kind: "profile", schema: 2, keyID: key.id),
            CloudCryptoFixture.context(UUID())
        ]
        for changed in contexts {
            #expect(throws: (any Error).self) { try CloudPayloadCipher.open(encrypted, key: key, context: changed) }
        }
        let wrong = try CloudCryptoFixture.key(id: key.id)
        #expect(throws: (any Error).self) { try CloudPayloadCipher.open(encrypted, key: wrong, context: context) }
        for index in encrypted.indices {
            var damaged = encrypted
            damaged[index] ^= 1
            #expect(throws: (any Error).self) { try CloudPayloadCipher.open(damaged, key: key, context: context) }
        }
        for length in [0, 1, 27, encrypted.count - 1] {
            #expect(throws: (any Error).self) { try CloudPayloadCipher.open(encrypted.prefix(length), key: key, context: context) }
        }
        // Even relabelling the same key bytes must not bypass key-ID authentication.
        let relabelled = try CloudEncryptionKey(id: contexts.last!.keyID, bytes: key.bytes)
        #expect(throws: (any Error).self) { try CloudPayloadCipher.open(encrypted, key: relabelled, context: contexts.last!) }
    }

    @Test func fixedZoneIsAuthenticatedAndCanonicalFieldsAreUnambiguous() throws {
        let key = try CloudCryptoFixture.key()
        let context = CloudCryptoFixture.context(key.id)
        let encrypted = try CloudPayloadCipher.seal(Data([1, 2, 3]), key: key, context: context)
        // Independently specify the wire contract, then alter the zone only.
        func aad(zone: String) -> Data {
            let fields = ["CloudPayload.v1", "iCloud.com.linda.CodexPlusBar", "development", "synthetic-owner",
                          zone, "profile.test", "profile", "1", key.id.uuidString.lowercased()]
            return Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        }
        let box = try AES.GCM.SealedBox(combined: encrypted)
        #expect(try AES.GCM.open(box, using: SymmetricKey(data: key.bytes), authenticating: aad(zone: "AccountSyncV1")) == Data([1, 2, 3]))
        #expect(throws: (any Error).self) {
            try AES.GCM.open(box, using: SymmetricKey(data: key.bytes), authenticating: aad(zone: "other-zone"))
        }
        let composed = CloudPayloadContext(owner: .init(container: "a:b", environment: .development, userRecordName: "é"), recordName: "x", kind: "y", schema: 1, keyID: key.id)
        let decomposed = CloudPayloadContext(owner: .init(container: "a:b", environment: .development, userRecordName: "e\u{301}"), recordName: "x", kind: "y", schema: 1, keyID: key.id)
        #expect(composed.authenticatedBytes == decomposed.authenticatedBytes)
        let shifted = CloudPayloadContext(owner: composed.owner, recordName: "x:y", kind: "", schema: 1, keyID: key.id)
        #expect(composed.authenticatedBytes != shifted.authenticatedBytes)
    }

    @Test func exactAssetLimitIncludesNonceAndTagBeforeAcceptingPlaintext() throws {
        let key = try CloudCryptoFixture.key()
        let context = CloudCryptoFixture.context(key.id)
        let maximum = 16 * 1_024 * 1_024
        let payload = Data(repeating: 0x91, count: maximum - 28)
        let encrypted = try CloudPayloadCipher.seal(payload, key: key, context: context)
        #expect(encrypted.count == maximum)
        #expect(try CloudPayloadCipher.open(encrypted, key: key, context: context) == payload)
        #expect(throws: CloudPayloadError.tooLarge) {
            try CloudPayloadCipher.seal(Data(repeating: 1, count: maximum - 27), key: key, context: context)
        }
        #expect(throws: CloudPayloadError.tooLarge) {
            try CloudPayloadCipher.open(Data(repeating: 1, count: maximum + 1), key: key, context: context)
        }
    }

    @Test func keyLengthAndSealKeyIDAreValidated() throws {
        for size in [0, 16, 31, 33, 64] {
            #expect(throws: CloudPayloadError.invalidKey) { try CloudEncryptionKey(id: UUID(), bytes: Data(repeating: 0, count: size)) }
        }
        let key = try CloudCryptoFixture.key()
        #expect(throws: CloudPayloadError.keyMismatch) {
            try CloudPayloadCipher.seal(Data([1]), key: key, context: CloudCryptoFixture.context(UUID()))
        }
    }

    @Test func privateStagingCopiesCiphertextAndRetainsItUntilEverySendReleases() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let store = CloudAssetStore(root: f.root)
        let key = try CloudCryptoFixture.key()
        let encrypted = try CloudPayloadCipher.seal(Data(UUID().uuidString.utf8), key: key, context: CloudCryptoFixture.context(key.id))
        let file = try store.stage(encrypted)
        #expect(try Data(contentsOf: file) == encrypted)
        #expect(try Self.mode(file) == 0o600)
        #expect(try Self.mode(f.root) == 0o700)
        let copied = try store.copyBounded(from: file)
        #expect(copied != file)
        #expect(try Data(contentsOf: copied) == encrypted)
        let lease = try store.retainForSend(file)
        let second = try CloudAssetStore(root: f.root).retainForSend(file)
        #expect(throws: CloudAssetError.inUse) { try store.remove(file) }
        lease.release()
        #expect(throws: CloudAssetError.inUse) { try CloudAssetStore(root: f.root).remove(file) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        second.release()
        try CloudAssetStore(root: f.root).remove(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: copied.path))
        try store.remove(copied)
    }

    @Test func copiesAreBoundedAndRejectNonregularSourcesWithoutBlocking() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let store = CloudAssetStore(root: f.root)
        let maximum = 16 * 1_024 * 1_024
        let file = try store.stage(Data(repeating: 3, count: maximum))
        let copy = try store.copyBounded(from: file)
        #expect(try Data(contentsOf: copy).count == maximum)
        #expect(throws: CloudJournalError.tooLarge) { try store.stage(Data(repeating: 3, count: maximum + 1)) }
        let oversized = f.base.appendingPathComponent("huge-encrypted.asset")
        let fd = open(oversized.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(ftruncate(fd, off_t(maximum + 1)) == 0)
        #expect(throws: CloudJournalError.tooLarge) { try store.copyBounded(from: oversized) }
        #expect(ftruncate(fd, off_t(1) << 40) == 0)
        #expect(throws: CloudJournalError.tooLarge) { try store.copyBounded(from: oversized) }
        let fifo = f.base.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try store.copyBounded(from: fifo) }
        #expect(throws: (any Error).self) { try store.copyBounded(from: f.base) }
        let link = f.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try store.copyBounded(from: link) }
        let parentLink = f.base.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: f.root)
        #expect(throws: (any Error).self) { try store.copyBounded(from: parentLink.appendingPathComponent(file.lastPathComponent)) }
    }

    @Test func stagingCannotRemoveOutsideFilesOrAdoptUnsafeRoots() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let store = CloudAssetStore(root: f.root)
        let outside = f.base.appendingPathComponent(UUID().uuidString.lowercased() + ".asset")
        try Data([7]).write(to: outside)
        #expect(throws: CloudJournalError.unsafePath) { try store.remove(outside) }
        #expect(try Data(contentsOf: outside) == Data([7]))
        let file = try store.stage(Data([8]))
        #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: CloudJournalError.unsafePath) { try store.remove(file) }
        #expect(chmod(file.path, 0o600) == 0)
        let link = f.base.appendingPathComponent("staging-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
        #expect(throws: (any Error).self) { try CloudAssetStore(root: link).stage(Data([9])) }
        #expect(chmod(f.root.path, 0o755) == 0)
        #expect(throws: CloudJournalError.unsafePath) { try store.stage(Data([9])) }
    }

    @Test func uncertainStageIsRetainedAndNeverDeletesAnOperationOwnedAsset() throws {
        let f = try CloudCryptoFixture(); defer { f.cleanUp() }
        let original = CloudAssetStore(root: f.root)
        let held = try original.stage(Data([1, 2, 3]))
        let lease = try original.retainForSend(held)
        defer { lease.release() }
        let failing = CloudAssetStore(root: f.root, io: .init { operation, _ in
            if operation == .directorySync { throw POSIXError(.ENOSPC) }
        })
        #expect(throws: (any Error).self) { try failing.stage(Data([4, 5, 6])) }
        let assets = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "asset" }
        #expect(assets.count == 2)
        #expect(try Data(contentsOf: held) == Data([1, 2, 3]))
        #expect(throws: CloudAssetError.inUse) { try failing.remove(held) }
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

struct CloudCryptoFixture {
    static let owner = CloudOwner(container: "iCloud.com.linda.CodexPlusBar", environment: .development, userRecordName: "synthetic-owner")
    let base: URL
    var root: URL { base.appendingPathComponent("private-store") }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-crypto-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    static func key(id: UUID = UUID()) throws -> CloudEncryptionKey {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try CloudEncryptionKey(id: id, bytes: bytes)
    }

    static func context(_ id: UUID) -> CloudPayloadContext {
        CloudPayloadContext(owner: owner, recordName: "profile.test", kind: "profile", schema: 1, keyID: id)
    }
}
