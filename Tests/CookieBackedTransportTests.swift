import Foundation
import Testing
@testable import CodexPlusBar

@MainActor
struct CookieBackedTransportTests {
    @Test
    func signedRequestUsesOnlyProvidedProfileCookies() throws {
        let freshCookie = try makeCookie(
            name: "__Secure-next-auth.session-token",
            value: "fresh"
        )
        let request = AuthSessionService.makeCurrentSessionRequest()

        let signedRequest = CookieBackedTransport.makeSignedRequest(
            request,
            cookies: [freshCookie],
            authContext: nil
        )

        let cookieHeader = try #require(
            signedRequest.value(forHTTPHeaderField: "Cookie")
        )
        #expect(cookieHeader.contains("__Secure-next-auth.session-token=fresh"))
        #expect(cookieHeader.contains("session-token.0") == false)
        #expect(cookieHeader.contains("session-token.1") == false)
        #expect(signedRequest.httpShouldHandleCookies == false)
    }

    @Test
    func claudeRequestUsesClaudeCookiesWithoutChatGPTHeaders() throws {
        let cookie = try makeCookie(
            name: "sessionKey",
            value: "claude-session",
            domain: ".claude.ai"
        )
        var request = ClaudeUsageService.makeUsageRequest()
        request.setValue("Bearer old-token", forHTTPHeaderField: "Authorization")
        request.setValue("old-account", forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")

        let signedRequest = CookieBackedTransport.makeSignedRequest(
            request,
            cookies: [cookie],
            authContext: nil
        )

        #expect(
            signedRequest.value(forHTTPHeaderField: "Cookie")?
                .contains("sessionKey=claude-session") == true
        )
        #expect(signedRequest.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(
            signedRequest.value(forHTTPHeaderField: "Referer")
                == ClaudeWebURLs.usagePage.absoluteString
        )
        #expect(signedRequest.value(forHTTPHeaderField: "Origin") == nil)
        #expect(signedRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(signedRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
        #expect(signedRequest.httpShouldHandleCookies == false)
    }
}

private func makeCookie(
    name: String,
    value: String,
    domain: String = ".chatgpt.com"
) throws -> HTTPCookie {
    try #require(
        HTTPCookie(
            properties: [
                .name: name,
                .value: value,
                .domain: domain,
                .path: "/",
                .secure: "TRUE",
            ]
        )
    )
}
