import Foundation
import Testing
@testable import CodexPlusBar

struct ChatGPTRequestSignerTests {
    @Test
    func signsBackendRequestsWithBearerAndWorkspaceHeaders() {
        let context = ChatGPTAuthContext(
            accessToken: "token-alpha",
            accountID: "workspace-a",
            expiresAt: nil,
            deviceID: "device-123",
            clientVersion: "prod-build-123",
            language: "en-US"
        )
        let request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)

        let signedRequest = ChatGPTRequestSigner.sign(request, cookies: [], authContext: context)

        #expect(signedRequest.value(forHTTPHeaderField: "Authorization") == "Bearer token-alpha")
        #expect(signedRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "workspace-a")
        #expect(signedRequest.value(forHTTPHeaderField: "OAI-Device-Id") == "device-123")
        #expect(signedRequest.value(forHTTPHeaderField: "OAI-Client-Version") == "prod-build-123")
        #expect(signedRequest.value(forHTTPHeaderField: "OAI-Language") == "en-US")
        #expect(signedRequest.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(signedRequest.value(forHTTPHeaderField: "Referer") == ChatGPTWebURLs.codexPage.absoluteString)
        #expect(signedRequest.value(forHTTPHeaderField: "X-OpenAI-Target-Path") == "/backend-api/wham/usage")
        #expect(signedRequest.value(forHTTPHeaderField: "X-OpenAI-Target-Route") == "/backend-api/wham/usage")
    }

    @Test
    func workspaceSwitchUsesTargetWorkspaceHeader() {
        let context = ChatGPTAuthContext(
            accessToken: "token-alpha",
            accountID: "workspace-a",
            expiresAt: nil,
            deviceID: "device-123",
            clientVersion: "prod-build-123",
            language: "en-US"
        )
        let request = AuthSessionService.makeWorkspaceSwitchRequest(workspaceID: "workspace-b")

        let signedRequest = ChatGPTRequestSigner.sign(request, cookies: [], authContext: context)

        #expect(signedRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(signedRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
        #expect(signedRequest.value(forHTTPHeaderField: "OAI-Language") == nil)
        #expect(signedRequest.value(forHTTPHeaderField: "OAI-Device-Id") == "device-123")
        #expect(signedRequest.value(forHTTPHeaderField: "OAI-Client-Version") == "prod-build-123")
        #expect(signedRequest.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(signedRequest.value(forHTTPHeaderField: "X-OpenAI-Target-Path") == "/api/auth/session")
        #expect(signedRequest.value(forHTTPHeaderField: "X-OpenAI-Target-Route") == "/api/auth/session")
        #expect(signedRequest.value(forHTTPHeaderField: "Origin") == nil)
    }

    @Test
    func preservesExplicitAccountHeaderForBackendRequests() {
        let context = ChatGPTAuthContext(
            accessToken: "token-alpha",
            accountID: "workspace-a",
            expiresAt: nil,
            deviceID: "device-123",
            clientVersion: "prod-build-123",
            language: "en-US"
        )
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("workspace-b", forHTTPHeaderField: "ChatGPT-Account-ID")

        let signedRequest = ChatGPTRequestSigner.sign(request, cookies: [], authContext: context)

        #expect(signedRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "workspace-b")
        #expect(signedRequest.value(forHTTPHeaderField: "Authorization") == "Bearer token-alpha")
    }

    @Test
    func currentSessionRequestStaysCookieOnly() {
        let context = ChatGPTAuthContext(
            accessToken: "token-alpha",
            accountID: "workspace-a",
            expiresAt: nil,
            deviceID: "device-123",
            clientVersion: "prod-build-123",
            language: "en-US"
        )
        let request = AuthSessionService.makeCurrentSessionRequest()

        let signedRequest = ChatGPTRequestSigner.sign(request, cookies: [], authContext: context)

        #expect(signedRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(signedRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
        #expect(signedRequest.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
        #expect(signedRequest.value(forHTTPHeaderField: "Referer") == ChatGPTWebURLs.usagePage.absoluteString)
        #expect(signedRequest.value(forHTTPHeaderField: "Origin") == nil)
    }
}
