import CryptoKit
import Foundation
import Testing
@testable import CodexPlusBar

struct CodexSignInTests {
    @Test func quotedDottedFeatureSettingsAreNotIgnored() throws {
        for key in ["features . secret_auth_storage", "\"features\".\"secret_auth_storage\""] {
            #expect(throws: CodexSignInError.unsupportedConfiguration) {
                try CodexAuthSettings(config: Data("\(key) = true".utf8), requirements: nil)
            }
        }
    }

    @Test func absentFileCommitCannotOverwriteAnotherWritersCreation() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("auth.json")
        let other = try CodexSignInFixture.data(account: "other")
        try other.write(to: url)
        #expect(throws: OpenCodeOpenAIAuthError.changedWhileReading) {
            try OpenCodePrivateFile.write(Data("replacement".utf8), to: url, requireAbsent: true)
        }
        #expect(try Data(contentsOf: url) == other)
    }

    @Test func autoKeychainDisappearanceIsAStorageChangeNotSignedOut() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("cli_auth_credentials_store = 'auto'".utf8).write(to: home.appendingPathComponent("config.toml"))
        let keychain = MemoryCodexKeychain(try CodexSignInFixture.data())
        let store = try CodexLiveAuthStore(codexHome: home, keychain: keychain)
        keychain.clear()
        #expect(throws: CodexSignInError.concurrentChange) { try store.read() }
    }

    @Test func systemAuthenticationLayersCannotBeIgnored() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let system = home.appendingPathComponent("system-config.toml")
        try Data("cli_auth_credentials_store = 'keyring'".utf8).write(to: system)
        #expect(throws: CodexSignInError.unsupportedConfiguration) {
            try CodexLiveAuthStore(codexHome: home, keychain: MemoryCodexKeychain(), additionalConfiguration: [system])
        }
    }

    @Test func unknownInlineFeatureConfigurationDoesNotSilentlySelectDirectKeychain() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("cli_auth_credentials_store = 'auto'\nfeatures = { secret_auth_storage = true }".utf8)
            .write(to: home.appendingPathComponent("config.toml"))
        #expect(throws: CodexSignInError.unsupportedConfiguration) {
            try CodexLiveAuthStore(codexHome: home, keychain: MemoryCodexKeychain())
        }
    }

    @Test func preservesCompleteCredentialAndBindsUserAndWorkspace() throws {
        let data = try CodexSignInFixture.data(account: "workspace-a", user: "user-a")
        let signIn = try CodexSignIn(data: data)
        #expect(signIn.data == data)
        #expect(signIn.identity.accountID == "workspace-a")
        #expect(signIn.identity.userID == "user-a")
        #expect(signIn.identity.email == "studio@example.com")
        let other = try CodexSignIn(data: CodexSignInFixture.data(account: "workspace-b", user: "user-a"))
        #expect(!signIn.identity.matches(other.identity))
        #expect(signIn.identity.storageKey != other.identity.storageKey)
    }

    @Test func rejectsMixedAccountTokensAndAPIKeys() throws {
        var object = try CodexSignInFixture.object()
        var tokens = try #require(object["tokens"] as? [String: Any])
        tokens["account_id"] = "someone-else"
        object["tokens"] = tokens
        #expect(throws: CodexSignInError.invalidCredential) {
            try CodexSignIn(data: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: CodexSignInError.unsupportedCredential) {
            try CodexSignIn(data: Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic"}"#.utf8))
        }
    }

    @Test func vaultIsPrivateAndCatalogContainsIdentityOnly() throws {
        let directory = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = CodexSignInVault(homeDirectory: directory)
        let signIn = try CodexSignIn(data: CodexSignInFixture.data())
        try vault.save(signIn)
        #expect(try vault.load(signIn.identity).data == signIn.data)
        let attributes = try FileManager.default.attributesOfItem(atPath: vault.url(for: signIn.identity).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var profile = CodexSignInFixture.profile()
        profile.codexSignIn = signIn.identity
        let encoded = try JSONEncoder().encode(profile)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("refresh_token"))
        #expect(!text.contains("synthetic-refresh"))
        #expect(try JSONDecoder().decode(PlusProfile.self, from: encoded).codexSignIn == signIn.identity)
    }

    @Test func fileStoreDetectsCompetingWritesAndConfigurationChanges() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let initial = try CodexSignInFixture.data()
        let other = try CodexSignInFixture.data(account: "other")
        let auth = home.appendingPathComponent("auth.json")
        try initial.write(to: auth)
        let store = try CodexLiveAuthStore(codexHome: home, keychain: MemoryCodexKeychain())
        #expect(try store.read() == initial)
        try other.write(to: auth)
        #expect(throws: CodexSignInError.concurrentChange) { try store.replace(with: initial, expected: initial) }
        #expect(try Data(contentsOf: auth) == other)
        try Data("cli_auth_credentials_store = 'keyring'".utf8).write(to: home.appendingPathComponent("config.toml"))
        #expect(throws: CodexSignInError.configurationChanged) { try store.replace(with: initial, expected: other) }
    }

    @Test func autoStoragePrefersKeychainAndDoesNotTouchFallback() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("cli_auth_credentials_store = 'auto' # selected globally\n[other]\nname = 'example'".utf8)
            .write(to: home.appendingPathComponent("config.toml"))
        let fallback = try CodexSignInFixture.data(account: "fallback")
        try fallback.write(to: home.appendingPathComponent("auth.json"))
        let original = try CodexSignInFixture.data()
        let keychain = MemoryCodexKeychain(original)
        let store = try CodexLiveAuthStore(codexHome: home, keychain: keychain)
        #expect(try store.read() == original)
        let next = try CodexSignInFixture.data(account: "next")
        try store.replace(with: next, expected: original)
        #expect(try store.read() == next)
        #expect(try Data(contentsOf: home.appendingPathComponent("auth.json")) == fallback)
        let digest = SHA256.hash(data: Data(home.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(store.keychainAccount == "cli|" + String(digest.prefix(16)))
    }

    @Test(arguments: ["cli_auth_credentials_store = 'ephemeral'", "[features]\nsecret_auth_storage = true", "cli_auth_credentials_store = 'unknown'"])
    func unsupportedStorageNeverFallsBackToAuthFile(config: String) throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(config.utf8).write(to: home.appendingPathComponent("config.toml"))
        #expect(throws: CodexSignInError.unsupportedConfiguration) {
            try CodexLiveAuthStore(codexHome: home, keychain: MemoryCodexKeychain())
        }
    }
}

enum CodexSignInFixture {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-sign-in-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func jwt(_ claims: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).synthetic"
    }

    static func object(account: String = "workspace", user: String = "user", refresh: String = "synthetic-refresh", expired: Bool = false) throws -> [String: Any] {
        let auth = ["chatgpt_account_id": account, "chatgpt_user_id": user]
        let claims: [String: Any] = ["email": "studio@example.com", "https://api.openai.com/auth": auth,
                                     "https://api.openai.com/profile": ["email": "studio@example.com"],
                                     "exp": expired ? 1 : 4_000_000_000]
        let token = try jwt(claims)
        return ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "future_field": ["preserve": true],
                "tokens": ["id_token": token, "access_token": token, "refresh_token": refresh, "account_id": account],
                "last_refresh": "2026-09-29T00:00:00Z"]
    }

    static func data(account: String = "workspace", user: String = "user", refresh: String = "synthetic-refresh", expired: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(account: account, user: user, refresh: refresh, expired: expired), options: [.sortedKeys])
    }

    static func profile() -> PlusProfile {
        PlusProfile(id: UUID(), label: "studio@example.com", emailLink: nil, detectedNote: nil,
                    webDataStoreID: UUID(), sortOrder: 0, createdAt: .now, lastRefreshAt: nil, lastKnownState: .needsLogin)
    }
}

final class MemoryCodexKeychain: CodexKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    init(_ value: Data? = nil) { self.value = value }
    func read(account: String) throws -> Data? { lock.withLock { value } }
    func write(_ data: Data, account: String) throws { lock.withLock { value = data } }
    func remove(account: String) throws { lock.withLock { value = nil } }
    func insert(_ data: Data, account: String) throws {
        try lock.withLock {
            guard value == nil else { throw CodexSignInError.concurrentChange }
            value = data
        }
    }
    func clear() { lock.withLock { value = nil } }
}
