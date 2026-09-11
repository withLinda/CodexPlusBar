import Foundation
import Testing
@testable import CodexPlusBar

struct OpenCodeOpenAIAuthServiceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCHAMBER_RUNTIME_PROBE"] == "1"))
    func installedLocalRuntimeCanBeDiscoveredReadOnly() async throws {
        let runtime = try await OpenCodeLocalRuntime.discover()
        #expect(runtime.authURL.lastPathComponent == "auth.json")
        #expect(runtime.authURL.isFileURL)
    }

    @Test func roundTripKeepsOtherProvidersAndLatestRefreshTokens() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let first = try fixture.auth("first")
        let second = try fixture.auth("second")
        try fixture.write(first)
        var firstProfile = fixture.profile("first")
        firstProfile.openCodeOpenAIAccount = try await fixture.service.saveCurrent(for: firstProfile)
        try fixture.write(second)
        var secondProfile = fixture.profile("second")
        secondProfile.openCodeOpenAIAccount = try await fixture.service.saveCurrent(for: secondProfile)

        let rotated = try fixture.auth("second", refresh: "rotated-refresh", expires: 1234)
        try fixture.write(rotated)
        try await fixture.service.switchTo(profile: firstProfile)
        #expect(try fixture.current() == first)
        try await fixture.service.switchTo(profile: secondProfile)
        #expect(try fixture.current() == rotated)
        #expect(try fixture.othersUnchanged())
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.authURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let privateDirectory = fixture.home.appendingPathComponent("Library/Application Support/CodexPlusBar/OpenChamberSignIns")
        let files = try FileManager.default.contentsOfDirectory(at: privateDirectory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: privateDirectory.path)
        #expect((directoryPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func sameAccountNeverRestoresStaleTokens() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.auth("first"))
        var profile = fixture.profile("first")
        profile.openCodeOpenAIAccount = try await fixture.service.saveCurrent(for: profile)
        let rotated = try fixture.auth("first", refresh: "latest-refresh")
        try fixture.write(rotated)
        let before = try Data(contentsOf: fixture.authURL)
        try await fixture.service.switchTo(profile: profile)
        #expect(try Data(contentsOf: fixture.authURL) == before)
    }

    @Test func wrongProfileAndClaudeCannotCaptureCredential() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.auth("first"))
        await #expect(throws: OpenCodeOpenAIAuthError.identityMismatch) {
            try await fixture.service.saveCurrent(for: fixture.profile("second"))
        }
        var claude = fixture.profile("first")
        claude.provider = .claude
        await #expect(throws: OpenCodeOpenAIAuthError.identityMismatch) {
            try await fixture.service.saveCurrent(for: claude)
        }
    }

    @Test func linkedAccountRequiresBothUserAndWorkspaceIdentity() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.auth("first"))
        var profile = fixture.profile("first")
        profile.codexAccountKey = "linked"
        let directory = fixture.home.appendingPathComponent(".codex/accounts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry: [String: Any] = ["accounts": [["account_key": "linked", "email": "first@example.com",
            "chatgpt_account_id": "different-workspace", "chatgpt_user_id": "user-first"]]]
        try JSONSerialization.data(withJSONObject: registry).write(to: directory.appendingPathComponent("registry.json"))
        await #expect(throws: OpenCodeOpenAIAuthError.identityMismatch) {
            try await fixture.service.saveCurrent(for: profile)
        }
    }

    @Test func profileCatalogContainsIdentityButNeverTokens() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let auth = try fixture.auth("first", refresh: "private-refresh-sentinel")
        try fixture.write(auth)
        var profile = fixture.profile("first")
        profile.openCodeOpenAIAccount = try await fixture.service.saveCurrent(for: profile)
        let encoded = try JSONEncoder().encode(profile)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(auth.refresh))
        #expect(!text.contains(auth.access))
        #expect(try JSONDecoder().decode(PlusProfile.self, from: encoded) == profile)
        profile.openCodeOpenAIAccount = nil
        let legacy = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(PlusProfile.self, from: legacy).openCodeOpenAIAccount == nil)
    }

    @Test func apiKeyOrMalformedStoreIsNeverOverwritten() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.auth("first"))
        var profile = fixture.profile("first")
        profile.openCodeOpenAIAccount = try await fixture.service.saveCurrent(for: profile)
        for text in ["{invalid-json", "{\"openai\":{\"type\":\"api\",\"key\":\"fixture-key\"}}", "{}"] {
            let before = Data(text.utf8)
            try before.write(to: fixture.authURL)
            await #expect(throws: (any Error).self) { try await fixture.service.switchTo(profile: profile) }
            #expect(try Data(contentsOf: fixture.authURL) == before)
        }
    }

    @Test func missingAndTamperedSnapshotsCannotSwitch() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let first = try fixture.auth("first")
        try fixture.write(first)
        var profile = fixture.profile("second")
        profile.openCodeOpenAIAccount = try fixture.auth("second").identity()
        await #expect(throws: OpenCodeOpenAIAuthError.profileCredentialMissing) {
            try await fixture.service.switchTo(profile: profile)
        }
        let saved = fixture.home.appendingPathComponent("Library/Application Support/CodexPlusBar/OpenChamberSignIns")
            .appendingPathComponent(try fixture.auth("second").identity().storageKey + ".json")
        try JSONEncoder().encode(first).write(to: saved)
        await #expect(throws: OpenCodeOpenAIAuthError.identityMismatch) {
            try await fixture.service.switchTo(profile: profile)
        }
        #expect(try fixture.current() == first)
    }

    @Test func invalidJWTAccountIsRejected() throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let original = try fixture.auth("first")
        let invalid = OpenCodeOpenAIAuth(type: "oauth", refresh: original.refresh, access: original.access,
                                        expires: 10, accountId: "wrong")
        #expect(throws: OpenCodeOpenAIAuthError.invalidCredential) { try invalid.identity() }
    }

    @Test func runtimeResolutionFailureLeavesAuthUntouched() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.auth("first"))
        let before = try Data(contentsOf: fixture.authURL)
        let service = OpenCodeOpenAIAuthService(homeDirectory: fixture.home, resolveRuntime: {
            throw OpenCodeOpenAIAuthError.localInstanceRequired
        })
        await #expect(throws: OpenCodeOpenAIAuthError.localInstanceRequired) {
            try await service.saveCurrent(for: fixture.profile("first"))
        }
        #expect(try Data(contentsOf: fixture.authURL) == before)
    }

    @Test func customDataHomeAndEnvironmentOverridesAreHandled() throws {
        #expect(try OpenCodeLocalRuntime.authURL(environment: ["HOME": "/fixture"]).path == "/fixture/.local/share/opencode/auth.json")
        #expect(try OpenCodeLocalRuntime.authURL(environment: ["HOME": "/fixture", "XDG_DATA_HOME": "/custom data"]).path == "/custom data/opencode/auth.json")
        for key in ["OPENCODE_AUTH_CONTENT", "OPENCODE_DATA_DIR"] {
            #expect(throws: OpenCodeOpenAIAuthError.environmentOverride) {
                try OpenCodeLocalRuntime.authURL(environment: ["HOME": "/fixture", key: "override"])
            }
        }
    }

    @Test func competingWriteIsDetectedWithoutChangingFile() throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let current = Data("changed".utf8)
        try current.write(to: fixture.authURL)
        #expect(throws: OpenCodeOpenAIAuthError.changedWhileReading) {
            try OpenCodePrivateFile.write(Data("target".utf8), to: fixture.authURL, expected: Data("old".utf8))
        }
        #expect(try Data(contentsOf: fixture.authURL) == current)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.authURL.deletingLastPathComponent().path) == ["auth.json"])
    }
}

private struct OpenCodeAuthFixture: Sendable {
    let home: URL
    let authURL: URL
    let service: OpenCodeOpenAIAuthService

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("openchamber-test-\(UUID())")
        authURL = home.appendingPathComponent(".local/share/opencode/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let runtime = OpenCodeLocalRuntime(authURL: authURL)
        service = OpenCodeOpenAIAuthService(homeDirectory: home, resolveRuntime: { runtime })
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func profile(_ name: String) -> PlusProfile {
        PlusProfile(id: UUID(), label: name + "@example.com", emailLink: nil, detectedNote: nil,
                    webDataStoreID: UUID(), sortOrder: 0, createdAt: .now, lastRefreshAt: nil, lastKnownState: .unknown)
    }

    func auth(_ name: String, refresh: String = "fixture-refresh", expires: Int64 = 0) throws -> OpenCodeOpenAIAuth {
        let claims: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-" + name, "chatgpt_user_id": "user-" + name],
            "https://api.openai.com/profile": ["email": name + "@example.com"]
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return OpenCodeOpenAIAuth(type: "oauth", refresh: refresh, access: "fixture.\(payload).signature",
                                 expires: expires, accountId: "account-" + name)
    }

    func write(_ auth: OpenCodeOpenAIAuth) throws {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))
        let root: [String: Any] = ["openai": value, "anthropic": ["type": "oauth", "refresh": "claude-keep"],
                                   "future-provider": ["unknown": ["nested", "values"], "enabled": true]]
        try JSONSerialization.data(withJSONObject: root).write(to: authURL)
    }

    func current() throws -> OpenCodeOpenAIAuth {
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any])
        let openai = try #require(root["openai"])
        return try JSONDecoder().decode(OpenCodeOpenAIAuth.self, from: JSONSerialization.data(withJSONObject: openai))
    }

    func othersUnchanged() throws -> Bool {
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any])
        return NSDictionary(dictionary: root.filter { $0.key != "openai" }).isEqual(to: [
            "anthropic": ["type": "oauth", "refresh": "claude-keep"],
            "future-provider": ["unknown": ["nested", "values"], "enabled": true]
        ])
    }
}
