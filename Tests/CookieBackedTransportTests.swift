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
}

private func makeCookie(name: String, value: String) throws -> HTTPCookie {
    try #require(
        HTTPCookie(
            properties: [
                .name: name,
                .value: value,
                .domain: ".chatgpt.com",
                .path: "/",
                .secure: "TRUE",
            ]
        )
    )
}
