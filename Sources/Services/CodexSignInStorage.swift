import CryptoKit
import Foundation
import Security

protocol CodexKeychainStoring: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func insert(_ data: Data, account: String) throws
    func remove(account: String) throws
}

struct CodexKeychain: CodexKeychainStoring {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Codex Auth", kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CodexSignInError.keychainUnavailable }
        return data
    }

    func write(_ data: Data, account: String) throws {
        let query = query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CodexSignInError.keychainUnavailable }
        } else if status != errSecSuccess {
            throw CodexSignInError.keychainUnavailable
        }
    }

    func insert(_ data: Data, account: String) throws {
        var item = query(account)
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw CodexSignInError.concurrentChange }
        guard status == errSecSuccess else { throw CodexSignInError.keychainUnavailable }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CodexSignInError.keychainUnavailable }
    }
}

/// Resolves once per transaction and checks both configuration and storage before each write.
struct CodexLiveAuthStore: Sendable {
    private enum Backend { case file, keychain }
    let codexHome: URL
    let keychainAccount: String
    private let backend: Backend
    private let keychain: any CodexKeychainStoring
    private let configuration: Data?
    private let requirements: Data?
    private let settings: CodexAuthSettings
    private let autoMode: Bool
    private let additionalConfiguration: [URL]

    init(codexHome: URL, keychain: any CodexKeychainStoring = CodexKeychain(),
         additionalConfiguration: [URL] = [URL(fileURLWithPath: "/etc/codex/config.toml"),
                                           URL(fileURLWithPath: "/etc/codex/requirements.toml"),
                                           URL(fileURLWithPath: "/etc/codex/managed_config.toml")]) throws {
        self.codexHome = codexHome.resolvingSymlinksInPath()
        self.keychain = keychain
        self.additionalConfiguration = additionalConfiguration
        try Self.rejectUnsupportedLayers(additionalConfiguration)
        let digest = SHA256.hash(data: Data(self.codexHome.path.utf8)).map { String(format: "%02x", $0) }.joined()
        keychainAccount = "cli|" + String(digest.prefix(16))
        configuration = try Self.readOptional(self.codexHome.appendingPathComponent("config.toml"))
        requirements = try Self.readOptional(self.codexHome.appendingPathComponent("requirements.toml"))
        settings = try CodexAuthSettings(config: configuration, requirements: requirements)
        autoMode = settings.storage == "auto"
        switch settings.storage {
        case "file": backend = .file
        case "keyring": backend = .keychain
        case "auto": backend = try keychain.read(account: keychainAccount) == nil ? .file : .keychain
        default: throw CodexSignInError.unsupportedConfiguration
        }
    }

    func validate(_ signIn: CodexSignIn) throws {
        if let workspace = settings.workspace, workspace != signIn.identity.accountID {
            throw CodexSignInError.identityMismatch
        }
    }

    func read() throws -> Data? {
        try requireConfigurationUnchanged()
        switch backend {
        case .file:
            if autoMode, try keychain.read(account: keychainAccount) != nil { throw CodexSignInError.concurrentChange }
            return try Self.readOptional(codexHome.appendingPathComponent("auth.json"))
        case .keychain:
            let data = try keychain.read(account: keychainAccount)
            if autoMode, data == nil { throw CodexSignInError.concurrentChange }
            return data
        }
    }

    func replace(with data: Data, expected: Data?) throws {
        guard try read() == expected else { throw CodexSignInError.concurrentChange }
        switch backend {
        case .file:
            do { try OpenCodePrivateFile.write(data, to: codexHome.appendingPathComponent("auth.json"), expected: expected, requireAbsent: expected == nil) }
            catch OpenCodeOpenAIAuthError.changedWhileReading { throw CodexSignInError.concurrentChange }
            catch { throw CodexSignInError.storageFailed }
        case .keychain:
            if expected == nil { try keychain.insert(data, account: keychainAccount) }
            else { try keychain.write(data, account: keychainAccount) }
        }
        guard try read() == data else { throw CodexSignInError.concurrentChange }
    }

    func remove(expected: Data) throws {
        guard try read() == expected else { throw CodexSignInError.concurrentChange }
        switch backend {
        case .file:
            do { try FileManager.default.removeItem(at: codexHome.appendingPathComponent("auth.json")) }
            catch { throw CodexSignInError.storageFailed }
        case .keychain: try keychain.remove(account: keychainAccount)
        }
        guard try read() == nil else { throw CodexSignInError.concurrentChange }
    }

    private func requireConfigurationUnchanged() throws {
        try Self.rejectUnsupportedLayers(additionalConfiguration)
        guard try Self.readOptional(codexHome.appendingPathComponent("config.toml")) == configuration,
              try Self.readOptional(codexHome.appendingPathComponent("requirements.toml")) == requirements else {
            throw CodexSignInError.configurationChanged
        }
    }

    private static func rejectUnsupportedLayers(_ urls: [URL]) throws {
        for url in urls where try readOptional(url)?.isEmpty == false {
            throw CodexSignInError.unsupportedConfiguration
        }
        // Upstream reads only forced (MDM) values in this domain, not ordinary defaults.
        for key in ["config_toml_base64", "requirements_toml_base64"] {
            if CFPreferencesAppValueIsForced(key as CFString, "com.openai.codex" as CFString) {
                throw CodexSignInError.unsupportedConfiguration
            }
        }
    }

    private static func readOptional(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CodexSignInError.unsupportedConfiguration
            }
            return try Data(contentsOf: url)
        } catch let error as CodexSignInError { throw error }
        catch { throw CodexSignInError.storageFailed }
    }
}

struct CodexSignInVault: Sendable {
    let directory: URL

    init(homeDirectory: URL) {
        directory = homeDirectory.appendingPathComponent("Library/Application Support/CodexPlusBar/DesktopSignIns")
    }

    func url(for identity: CodexSignInIdentity) -> URL { directory.appendingPathComponent(identity.storageKey + ".json") }

    func save(_ signIn: CodexSignIn) throws {
        let signIn = try latestGeneration(of: signIn)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try OpenCodePrivateFile.write(signIn.data, to: url(for: signIn.identity))
        } catch { throw CodexSignInError.storageFailed }
    }

    /// Persist the consumed-generation mapping before updating the main snapshot or live store.
    func saveRefreshed(_ refreshed: CodexSignIn, replacing previous: CodexSignIn) throws {
        guard previous.identity.matches(refreshed.identity) else { throw CodexSignInError.identityMismatch }
        if previous.refreshToken != refreshed.refreshToken {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try OpenCodePrivateFile.write(refreshed.data, to: rotationURL(for: previous))
            } catch { throw CodexSignInError.storageFailed }
        }
        try save(refreshed)
    }

    func latestGeneration(of signIn: CodexSignIn) throws -> CodexSignIn {
        var current = signIn
        var seen = Set<URL>()
        while FileManager.default.fileExists(atPath: rotationURL(for: current).path) {
            let url = rotationURL(for: current)
            guard seen.insert(url).inserted else { throw CodexSignInError.storageFailed }
            let next: CodexSignIn
            do { next = try CodexSignIn(data: Data(contentsOf: url)) }
            catch { throw CodexSignInError.storageFailed }
            guard current.identity.matches(next.identity) else { throw CodexSignInError.identityMismatch }
            current = next
        }
        return current
    }

    private func rotationURL(for signIn: CodexSignIn) -> URL {
        let digest = SHA256.hash(data: Data(signIn.refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(signIn.identity.storageKey + ".consumed-" + digest + ".json")
    }

    func load(_ identity: CodexSignInIdentity) throws -> CodexSignIn {
        guard FileManager.default.fileExists(atPath: url(for: identity).path) else { throw CodexSignInError.missingSavedSignIn }
        let data: Data
        do { data = try Data(contentsOf: url(for: identity)) }
        catch { throw CodexSignInError.storageFailed }
        let signIn = try CodexSignIn(data: data)
        guard identity.matches(signIn.identity) else { throw CodexSignInError.identityMismatch }
        return try latestGeneration(of: signIn)
    }
}

/// Reads only authentication selectors. Complex/unknown auth settings fail closed.
/// Unrelated tables and multiline prompts are skipped rather than interpreted as settings.
struct CodexAuthSettings {
    var storage = "file"
    var workspace: String?

    init(config: Data?, requirements: Data?) throws {
        try apply(config)
        try apply(requirements)
    }

    private mutating func apply(_ data: Data?) throws {
        guard let data else { return }
        guard let text = String(data: data, encoding: .utf8) else { throw CodexSignInError.unsupportedConfiguration }
        var table = ""
        var multiline: String?
        for raw in text.components(separatedBy: .newlines) {
            if let delimiter = multiline {
                if raw.contains(delimiter) { multiline = nil }
                continue
            }
            let line = Self.withoutComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { table = line; continue }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let rawKey = String(line[..<equal])
            guard !rawKey.contains("\\") else { throw CodexSignInError.unsupportedConfiguration }
            let key = rawKey.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if key == "features", table.isEmpty { throw CodexSignInError.unsupportedConfiguration }
            let relevant = ["cli_auth_credentials_store", "forced_login_method", "forced_chatgpt_workspace_id", "chatgpt_base_url", "secret_auth_storage", "features.secret_auth_storage"].contains(key)
            if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") {
                if relevant { throw CodexSignInError.unsupportedConfiguration }
                let delimiter = String(value.prefix(3))
                if !value.dropFirst(3).contains(delimiter) { multiline = delimiter }
                continue
            }
            guard relevant else { continue }
            if key == "secret_auth_storage" || key == "features.secret_auth_storage" {
                guard value == "false" else { throw CodexSignInError.unsupportedConfiguration }
                continue
            }
            guard table.isEmpty, value.count >= 2,
                  (value.first == "\"" || value.first == "'"), value.last == value.first else {
                throw CodexSignInError.unsupportedConfiguration
            }
            let scalar = String(value.dropFirst().dropLast())
            guard !scalar.contains("\\") else { throw CodexSignInError.unsupportedConfiguration }
            switch key {
            case "cli_auth_credentials_store": storage = scalar
            case "forced_chatgpt_workspace_id": workspace = scalar.isEmpty ? nil : scalar
            case "forced_login_method":
                guard scalar == "chatgpt" else { throw CodexSignInError.unsupportedConfiguration }
            case "chatgpt_base_url":
                guard ["https://chatgpt.com", "https://chatgpt.com/"].contains(scalar) else { throw CodexSignInError.unsupportedConfiguration }
            default: break
            }
        }
    }

    private static func withoutComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let char = line[index]
            if escaped { escaped = false; continue }
            if char == "\\", quote == "\"" { escaped = true; continue }
            if let current = quote { if char == current { quote = nil } }
            else if char == "\"" || char == "'" { quote = char }
            else if char == "#" { return String(line[..<index]) }
        }
        return line
    }
}
