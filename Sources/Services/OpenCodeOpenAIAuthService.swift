import CryptoKit
import Darwin
import Foundation

struct OpenCodeOpenAIIdentity: Codable, Equatable, Sendable {
    let accountID: String
    let userID: String
    let email: String

    var storageKey: String {
        SHA256.hash(data: Data("\(accountID)\n\(userID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ other: Self) -> Bool {
        accountID == other.accountID && userID == other.userID
    }
}

/// OpenCode's OAuth format, not Codex CLI's `tokens` object.
struct OpenCodeOpenAIAuth: Codable, Equatable, Sendable {
    let type: String
    let refresh: String
    let access: String
    let expires: Int64
    let accountId: String

    func identity() throws -> OpenCodeOpenAIIdentity {
        guard type == "oauth" else { throw OpenCodeOpenAIAuthError.unsupportedCredential }
        guard !refresh.isEmpty, !access.isEmpty, expires >= 0 else { throw OpenCodeOpenAIAuthError.invalidCredential }
        let parts = access.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw OpenCodeOpenAIAuthError.invalidCredential }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = auth["chatgpt_account_id"] as? String, !account.isEmpty,
              account == accountId,
              let user = auth["chatgpt_user_id"] as? String, !user.isEmpty,
              let profile = claims["https://api.openai.com/profile"] as? [String: Any],
              let email = profile["email"] as? String, !email.isEmpty else {
            throw OpenCodeOpenAIAuthError.invalidCredential
        }
        // Local identity consistency check, not cryptographic JWT verification.
        return OpenCodeOpenAIIdentity(accountID: account, userID: user, email: email)
    }
}

enum OpenCodeOpenAIAuthError: LocalizedError, Equatable {
    case authFileMissing, providerMissing, unsupportedCredential, profileCredentialMissing
    case invalidCredential, identityMismatch, changedWhileReading, writeFailed
    case localInstanceRequired, ambiguousInstance, environmentOverride, runtimeUnavailable, busy

    var errorDescription: String? {
        switch self {
        case .authFileMissing: return "Sign in to OpenAI in the local OpenChamber instance first."
        case .providerMissing: return "No OpenAI sign-in was found in the local OpenChamber instance."
        case .unsupportedCredential: return "Connect OpenAI with ChatGPT in OpenChamber first. API-key connections cannot be switched here."
        case .profileCredentialMissing: return "Save this profile’s OpenChamber sign-in in the manager first."
        case .invalidCredential: return "This OpenChamber sign-in is incomplete. Sign in again in OpenChamber, then save it here."
        case .identityMismatch: return "The OpenChamber sign-in belongs to a different account. Select the matching profile and save again."
        case .changedWhileReading: return "OpenChamber changed its sign-in during the switch. Wait for its current work to finish, then try again."
        case .writeFailed: return "Could not save the OpenChamber sign-in. Check access to the local sign-in files."
        case .localInstanceRequired: return "Open the local instance in OpenChamber first. This action switches the local OpenAI connection."
        case .ambiguousInstance: return "More than one OpenCode process is using this sign-in store. Close the other instance, then switch again."
        case .environmentOverride: return "This OpenChamber instance overrides its sign-in store. Switching this configuration is not supported."
        case .runtimeUnavailable: return "Could not verify the local OpenChamber instance. Reopen it and try again."
        case .busy: return "Another OpenChamber sign-in action is still running."
        }
    }
}

protocol OpenCodeOpenAIAuthServing: Sendable {
    func saveCurrent(for profile: PlusProfile) async throws -> OpenCodeOpenAIIdentity
    func switchTo(profile: PlusProfile) async throws
}

/// Owns credentials off the UI actor. Never writes tokens to profiles.json or logs.
actor OpenCodeOpenAIAuthService: OpenCodeOpenAIAuthServing {
    private let homeDirectory: URL
    private let storeDirectory: URL
    private let resolveRuntime: @Sendable () async throws -> OpenCodeLocalRuntime
    private var isOperating = false

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         resolveRuntime: @escaping @Sendable () async throws -> OpenCodeLocalRuntime = {
             try await OpenCodeLocalRuntime.discover()
         }) {
        self.homeDirectory = homeDirectory
        storeDirectory = homeDirectory.appendingPathComponent("Library/Application Support/CodexPlusBar/OpenChamberSignIns")
        self.resolveRuntime = resolveRuntime
    }

    func saveCurrent(for profile: PlusProfile) async throws -> OpenCodeOpenAIIdentity {
        guard !isOperating else { throw OpenCodeOpenAIAuthError.busy }
        isOperating = true
        defer { isOperating = false }
        let runtime = try await resolveRuntime()
        try Task.checkCancellation()
        let auth = try credential(in: readStore(runtime.authURL).object)
        let identity = try auth.identity()
        try validate(identity, for: profile)
        try save(auth, identity: identity)
        return identity
    }

    func switchTo(profile: PlusProfile) async throws {
        guard !isOperating else { throw OpenCodeOpenAIAuthError.busy }
        isOperating = true
        defer { isOperating = false }
        guard profile.provider == .codex, let selected = profile.openCodeOpenAIAccount else {
            throw OpenCodeOpenAIAuthError.profileCredentialMissing
        }
        let runtime = try await resolveRuntime()
        try Task.checkCancellation()
        let original = try readStore(runtime.authURL)
        let outgoing = try credential(in: original.object)
        let outgoingIdentity = try outgoing.identity()

        // OpenCode rotates refresh tokens. Save the latest outgoing pair before
        // restoring another account; do not resurrect an old snapshot on a no-op.
        try save(outgoing, identity: outgoingIdentity)
        if selected.matches(outgoingIdentity) { return }
        let targetURL = storeURL(for: selected)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw OpenCodeOpenAIAuthError.profileCredentialMissing
        }
        let target: OpenCodeOpenAIAuth
        do { target = try JSONDecoder().decode(OpenCodeOpenAIAuth.self, from: Data(contentsOf: targetURL)) }
        catch { throw OpenCodeOpenAIAuthError.invalidCredential }
        guard try selected.matches(target.identity()) else { throw OpenCodeOpenAIAuthError.identityMismatch }
        var updated = original.object
        updated["openai"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
        let output = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try OpenCodePrivateFile.write(output, to: runtime.authURL, expected: original.data)
        let verified = try readStore(runtime.authURL)
        guard try selected.matches(credential(in: verified.object).identity()),
              NSDictionary(dictionary: withoutOpenAI(verified.object)).isEqual(to: withoutOpenAI(original.object)) else {
            throw OpenCodeOpenAIAuthError.changedWhileReading
        }
    }

    private func validate(_ identity: OpenCodeOpenAIIdentity, for profile: PlusProfile) throws {
        guard profile.provider == .codex else { throw OpenCodeOpenAIAuthError.identityMismatch }
        if let saved = profile.openCodeOpenAIAccount {
            guard saved.matches(identity) else { throw OpenCodeOpenAIAuthError.identityMismatch }
            return
        }
        if profile.codexAccountKey != nil {
            let account = try CodexAccountSwitchService(homeDirectory: homeDirectory).linkedAccount(for: profile)
            guard account.chatgptAccountID == identity.accountID, account.chatgptUserID == identity.userID else {
                throw OpenCodeOpenAIAuthError.identityMismatch
            }
        } else {
            guard profile.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == identity.email.lowercased() else {
                throw OpenCodeOpenAIAuthError.identityMismatch
            }
        }
    }

    private func readStore(_ url: URL) throws -> (data: Data, object: [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OpenCodeOpenAIAuthError.authFileMissing }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OpenCodeOpenAIAuthError.invalidCredential
            }
            return (data, object)
        } catch { throw OpenCodeOpenAIAuthError.invalidCredential }
    }

    private func credential(in root: [String: Any]) throws -> OpenCodeOpenAIAuth {
        guard let value = root["openai"] as? [String: Any] else { throw OpenCodeOpenAIAuthError.providerMissing }
        guard value["type"] as? String == "oauth" else { throw OpenCodeOpenAIAuthError.unsupportedCredential }
        do {
            let auth = try JSONDecoder().decode(OpenCodeOpenAIAuth.self, from: JSONSerialization.data(withJSONObject: value))
            _ = try auth.identity()
            return auth
        } catch { throw OpenCodeOpenAIAuthError.invalidCredential }
    }

    private func withoutOpenAI(_ root: [String: Any]) -> [String: Any] {
        root.filter { $0.key != "openai" }
    }

    private func storeURL(for identity: OpenCodeOpenAIIdentity) -> URL {
        storeDirectory.appendingPathComponent(identity.storageKey + ".json")
    }

    private func save(_ auth: OpenCodeOpenAIAuth, identity: OpenCodeOpenAIIdentity) throws {
        do {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDirectory.path)
            try OpenCodePrivateFile.write(JSONEncoder().encode(auth), to: storeURL(for: identity))
        } catch { throw OpenCodeOpenAIAuthError.writeFailed }
    }
}

enum OpenCodePrivateFile {
    /// Create private from the first byte, then atomically rename on the same volume.
    /// OpenCode does not participate in our lock: the optimistic check detects
    /// competing writes, but is not a cross-process compare-and-swap guarantee.
    static func write(_ data: Data, to url: URL, expected: Data? = nil) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".auth-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw OpenCodeOpenAIAuthError.writeFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            if let expected, try Data(contentsOf: url) != expected { throw OpenCodeOpenAIAuthError.changedWhileReading }
            guard rename(temporary.path, url.path) == 0 else { throw OpenCodeOpenAIAuthError.writeFailed }
        } catch let error as OpenCodeOpenAIAuthError { throw error }
        catch { throw OpenCodeOpenAIAuthError.writeFailed }
    }
}
