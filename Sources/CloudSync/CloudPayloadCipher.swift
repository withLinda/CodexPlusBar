import CryptoKit
import Foundation

enum CloudPayloadError: Error, Equatable, Sendable {
    case invalidKey, keyMismatch, tooLarge, authenticationFailed
}

struct CloudEncryptionKey: Equatable, Sendable {
    let id: UUID
    let bytes: Data
    init(id: UUID, bytes: Data) throws {
        guard bytes.count == 32 else { throw CloudPayloadError.invalidKey }
        self.id = id
        self.bytes = bytes
    }
}

struct CloudPayloadContext: Sendable {
    let owner: CloudOwner
    let recordName: String
    let kind: String
    let schema: Int
    let keyID: UUID
    static let zoneName = "AccountSyncV1"

    /// Wire contract: NFC UTF-8 fields, each prefixed with its decimal byte count and ':'.
    /// The domain separates this envelope from other uses of the same application key.
    var authenticatedBytes: Data {
        var bytes = Data()
        for value in ["CloudPayload.v1", owner.container, owner.environment.rawValue, owner.userRecordName,
                      Self.zoneName, recordName, kind, String(schema), keyID.uuidString.lowercased()] {
            let field = Data(value.precomposedStringWithCanonicalMapping.utf8)
            bytes.append(contentsOf: "\(field.count):".utf8)
            bytes.append(field)
        }
        return bytes
    }
}

enum CloudPayloadCipher {
    static let maximumAssetBytes = CloudSyncJournal.maximumAssetBytes
    // CryptoKit combined AES-GCM: 12-byte random nonce + ciphertext + 16-byte tag.
    static let combinedOverhead = 28
    static let maximumPlaintextBytes = maximumAssetBytes - combinedOverhead

    static func seal(_ plaintext: Data, key: CloudEncryptionKey, context: CloudPayloadContext) throws -> Data {
        guard plaintext.count <= maximumPlaintextBytes else { throw CloudPayloadError.tooLarge }
        guard key.id == context.keyID else { throw CloudPayloadError.keyMismatch }
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key.bytes),
                                   nonce: AES.GCM.Nonce(), authenticating: context.authenticatedBytes)
        guard let combined = box.combined else { throw CloudPayloadError.authenticationFailed }
        return combined
    }

    static func open(_ ciphertext: Data, key: CloudEncryptionKey, context: CloudPayloadContext) throws -> Data {
        guard ciphertext.count <= maximumAssetBytes else { throw CloudPayloadError.tooLarge }
        guard key.id == context.keyID else { throw CloudPayloadError.keyMismatch }
        guard ciphertext.count >= combinedOverhead else { throw CloudPayloadError.authenticationFailed }
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: SymmetricKey(data: key.bytes), authenticating: context.authenticatedBytes)
        } catch { throw CloudPayloadError.authenticationFailed }
    }
}
