import Foundation
import Testing
@testable import CodexPlusBar

struct CodexAccountSwitchServiceTests {
    @Test func importsLegacySnapshotWithoutHelperAndPreservesNewerNativeTokens() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/accounts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let signIn = try CodexSignIn(data: CodexSignInFixture.data())
        let registry: [String: Any] = ["accounts": [["account_key": "saved", "chatgpt_account_id": "workspace",
                                                    "chatgpt_user_id": "user", "email": "studio@example.com"]]]
        try JSONSerialization.data(withJSONObject: registry).write(to: directory.appendingPathComponent("registry.json"))
        try signIn.data.write(to: directory.appendingPathComponent("saved.auth.json"))
        var profile = CodexSignInFixture.profile()
        profile.codexAccountKey = "saved"
        profile.label = "My studio" // Explicit stable keys survive user-facing renames.
        let vault = CodexSignInVault(homeDirectory: home)
        let newer = try CodexSignIn(data: CodexSignInFixture.data(refresh: "newer-native"))
        try vault.save(newer)
        let result = CodexLegacySignInImporter(homeDirectory: home).migrate([profile])
        #expect(result.changed)
        #expect(result.0.first?.codexSignIn == signIn.identity)
        #expect(try vault.load(signIn.identity).refreshToken == "newer-native")
        #expect(try Data(contentsOf: directory.appendingPathComponent("saved.auth.json")) == signIn.data)
    }

    @Test func legacyEmailAmbiguityDoesNotChooseAnArbitraryWorkspace() throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/accounts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let accounts = ["first", "second"].map { ["account_key": $0, "chatgpt_account_id": $0,
                                                  "chatgpt_user_id": "user", "email": "studio@example.com"] }
        try JSONSerialization.data(withJSONObject: ["accounts": accounts]).write(to: directory.appendingPathComponent("registry.json"))
        #expect(throws: CodexSignInError.identityMismatch) {
            try CodexLegacySignInImporter(homeDirectory: home).linkedAccount(for: CodexSignInFixture.profile())
        }
    }

    @Test func verifiesAccountScopedUsageAndRejectsUnrelatedSuccessResponses() async throws {
        let signIn = try CodexSignIn(data: CodexSignInFixture.data())
        let verifier = CodexSignInVerifier(request: { request in
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == signIn.identity.accountID)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(signIn.accessToken)")
            #expect(!request.httpShouldHandleCookies)
            return (Data("<html>Sign in</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: CodexSignInError.invalidResponse) { try await verifier.verify(signIn) }
    }

    @Test func refreshPreservesUnknownFieldsAndReplacesAllReturnedTokens() async throws {
        let original = try CodexSignIn(data: CodexSignInFixture.data(expired: true))
        let next = try CodexSignIn(data: CodexSignInFixture.data(refresh: "rotated"))
        let verifier = CodexSignInVerifier(request: { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.host == "auth.openai.com")
            #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token"))
            let body = try JSONSerialization.data(withJSONObject: ["access_token": next.accessToken, "refresh_token": next.refreshToken])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let updated = try await verifier.refresh(original)
        #expect(updated.refreshToken == "rotated")
        #expect(updated.accessToken == next.accessToken)
        let object = try #require(JSONSerialization.jsonObject(with: updated.data) as? [String: Any])
        #expect((object["future_field"] as? [String: Bool])?["preserve"] == true)
    }
}
