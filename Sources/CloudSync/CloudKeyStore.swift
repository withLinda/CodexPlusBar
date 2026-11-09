import CryptoKit
import Foundation
import Security

protocol CloudKeyStoring: Sendable {
    func writerKey(owner: CloudOwner, deviceID: UUID) async throws -> CloudEncryptionKey
    func key(id: UUID, owner: CloudOwner) async throws -> CloudEncryptionKey?
}

enum CloudKeyStoreError: Error, Equatable, Sendable, LocalizedError {
    case waitingForKey(UUID), unavailable(OSStatus), securityFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .waitingForKey: "Waiting for the cloud encryption key from iCloud Keychain."
        case .unavailable: "The cloud encryption Keychain is temporarily unavailable. Unlock this Mac and try again."
        case .securityFailure: "The cloud encryption Keychain could not be accessed."
        }
    }
}

struct CloudSecurityResult: Sendable { let status: OSStatus; let data: Data? }

/// Synchronous boundary: dictionaries never cross an actor or an async suspension.
protocol CloudSecurityAdapting: Sendable {
    func copyMatching(_ query: [String: Any]) -> CloudSecurityResult
    func add(_ attributes: [String: Any]) -> OSStatus
}

struct CloudSystemSecurity: CloudSecurityAdapting {
    func copyMatching(_ query: [String: Any]) -> CloudSecurityResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return CloudSecurityResult(status: status, data: result as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

struct CloudKeyStore: CloudKeyStoring {
    static let service = "com.linda.CodexPlusBar.CloudSync.Keys.v1"
    static let accessGroup = "2Z8N5KTWQZ.com.linda.CodexPlusBar"
    private let journal: CloudSyncJournal
    private let security: any CloudSecurityAdapting

    init(journal: CloudSyncJournal, security: any CloudSecurityAdapting = CloudSystemSecurity()) {
        self.journal = journal
        self.security = security
    }

    func writerKey(owner: CloudOwner, deviceID: UUID) async throws -> CloudEncryptionKey {
        guard owner == journal.owner else { throw CloudJournalError.ownerMismatch }
        // The journal serializes setup across instances/processes. Key insertion precedes
        // the reference commit; a failed commit may leave an unused key, never a usable
        // uncommitted writer. A visible uncertain reference is recovered on the next load.
        let id = try await journal.writerKeyID(deviceID: deviceID) {
            let id = UUID()
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            var attributes = Self.identity(id: id, owner: owner)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecValueData as String] = bytes
            let status = security.add(attributes)
            if status == errSecDuplicateItem {
                // Never overwrite: validate and use the item occupying this exact UUID.
                guard try lookup(id: id, owner: owner) != nil else { throw CloudKeyStoreError.waitingForKey(id) }
            } else if status != errSecSuccess { throw Self.failure(status) }
            return id
        }
        guard let key = try lookup(id: id, owner: owner) else { throw CloudKeyStoreError.waitingForKey(id) }
        // Local insertion/readback says nothing about delivery to another Mac.
        return key
    }

    func key(id: UUID, owner: CloudOwner) async throws -> CloudEncryptionKey? {
        try lookup(id: id, owner: owner)
    }

    private func lookup(id: UUID, owner: CloudOwner) throws -> CloudEncryptionKey? {
        guard !owner.container.isEmpty, !owner.userRecordName.isEmpty else { throw CloudJournalError.invalidState }
        var query = Self.identity(id: id, owner: owner)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw Self.failure(result.status) }
        guard let bytes = result.data else { throw CloudPayloadError.invalidKey }
        return try CloudEncryptionKey(id: id, bytes: bytes)
    }

    private static func identity(id: UUID, owner: CloudOwner) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: CloudSyncPaths.ownerDigest(owner) + "." + id.uuidString.lowercased(),
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: true]
    }

    private static func failure(_ status: OSStatus) -> CloudKeyStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed: .unavailable(status)
        default: .securityFailure(status)
        }
    }
}
