import CryptoKit
import Foundation

/// Access is serialized by OpenCodeOperationGate. Only identity keys, never labels, form paths.
struct OpenCodeSignInSnapshotStore: Sendable {
    let directory: URL
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent("Library/Application Support/CodexPlusBar/OpenChamberSignIns")
    }
    func loadNativeValue(identity: OpenCodeOpenAIIdentity) throws -> OpenCodeCredentialValue? {
        let native = url(identity, ".native.json"), legacy = url(identity, ".json")
        let value: OpenCodeCredentialValue
        do {
            if FileManager.default.fileExists(atPath: native.path) {
                value = try JSONDecoder().decode(OpenCodeCredentialValue.self, from: Data(contentsOf: native))
            } else if FileManager.default.fileExists(atPath: legacy.path) {
                value = .legacy(try JSONDecoder().decode(OpenCodeOpenAIAuth.self, from: Data(contentsOf: legacy)))
            } else { return nil }
        } catch { throw OpenCodeOpenAIAuthError.invalidCredential }
        guard try value.auth().identity().matches(identity) else { throw OpenCodeOpenAIAuthError.identityMismatch }
        return try value.replacingTokens(resolved(value.auth()))
    }
    func saveNative(_ credential: OpenCodeStoredCredential, identity: OpenCodeOpenAIIdentity) throws {
        guard try credential.openAIIdentity().matches(identity) else { throw OpenCodeOpenAIAuthError.identityMismatch }
        try saveValue(credential.value, identity: identity)
        try saveBinding(id: credential.id, identity: identity)
    }
    func saveValue(_ value: OpenCodeCredentialValue, identity: OpenCodeOpenAIIdentity) throws {
        let auth = try resolved(value.auth())
        guard try auth.identity().matches(identity) else { throw OpenCodeOpenAIAuthError.identityMismatch }
        try prepare()
        try OpenCodePrivateFile.write(JSONEncoder().encode(value.replacingTokens(auth)), to: url(identity, ".native.json"))
        try OpenCodePrivateFile.write(JSONEncoder().encode(auth), to: url(identity, ".json"))
    }
    func binding(identity: OpenCodeOpenAIIdentity) throws -> String? {
        let file = url(identity, ".v2.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try JSONDecoder().decode(String.self, from: Data(contentsOf: file)) }
        catch { throw OpenCodeOpenAIAuthError.invalidCredential }
    }
    func saveBinding(id: String, identity: OpenCodeOpenAIIdentity) throws {
        try prepare()
        try OpenCodePrivateFile.write(JSONEncoder().encode(id), to: url(identity, ".v2.json"))
    }

    /// A refresh may consume the live token before installation succeeds. Keep its
    /// replacement across retries, even when a later native read still returns it.
    func saveRefreshed(_ auth: OpenCodeOpenAIAuth, replacing previous: OpenCodeOpenAIAuth) throws {
        let identity = try previous.identity()
        guard try auth.identity().matches(identity) else { throw OpenCodeOpenAIAuthError.identityMismatch }
        var replacements = try rotations(identity)
        if auth != previous { replacements[generationKey(previous)] = auth }
        try prepare()
        try OpenCodePrivateFile.write(JSONEncoder().encode(replacements), to: url(identity, ".rotations.json"))
        let value = try loadNativeValue(identity: identity) ?? .legacy(auth)
        try saveValue(value.replacingTokens(auth), identity: identity)
    }

    func resolved(_ auth: OpenCodeOpenAIAuth) throws -> OpenCodeOpenAIAuth {
        let identity = try auth.identity(), replacements = try rotations(identity)
        var current = auth, visited: Set<String> = []
        while let next = replacements[generationKey(current)] {
            guard visited.insert(generationKey(current)).inserted, try next.identity().matches(identity) else {
                throw OpenCodeOpenAIAuthError.invalidCredential
            }
            current = next
        }
        return current
    }

    private func rotations(_ identity: OpenCodeOpenAIIdentity) throws -> [String: OpenCodeOpenAIAuth] {
        let file = url(identity, ".rotations.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        do { return try JSONDecoder().decode([String: OpenCodeOpenAIAuth].self, from: Data(contentsOf: file)) }
        catch { throw OpenCodeOpenAIAuthError.invalidCredential }
    }
    private func generationKey(_ auth: OpenCodeOpenAIAuth) -> String {
        SHA256.hash(data: Data("\(auth.access)\n\(auth.refresh)\n\(auth.expires)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func url(_ identity: OpenCodeOpenAIIdentity, _ suffix: String) -> URL { directory.appendingPathComponent(identity.storageKey + suffix) }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
