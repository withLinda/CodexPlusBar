import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct ChromeCookieImporterTests {
    @Test
    func chatGPTCookiesFiltersAndConvertsSecureHTTPOnlyCookies() throws {
        let cookies = [
            ChromeDevToolsCookie(
                name: "__Secure-next-auth.session-token",
                value: "secret",
                domain: ".chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: true,
                secure: true
            ),
            ChromeDevToolsCookie(
                name: "oai-did",
                value: "device-a",
                domain: "chatgpt.com",
                path: "/",
                expires: 1_776_000_000,
                httpOnly: false,
                secure: true
            ),
            ChromeDevToolsCookie(
                name: "__Secure-next-auth.session-token",
                value: "wrong-site",
                domain: ".example.com",
                path: "/",
                expires: nil,
                httpOnly: true,
                secure: true
            ),
            ChromeDevToolsCookie(
                name: "__Secure-next-auth.session-token",
                value: "wrong-subdomain",
                domain: ".login.chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: true,
                secure: true
            ),
        ]

        let imported = try ChromeCookieImporter.chatGPTHTTPCookies(from: cookies)

        #expect(imported.map(\.name) == ["__Secure-next-auth.session-token", "oai-did"])

        let sessionCookie = try #require(imported.first)
        #expect(sessionCookie.domain == ".chatgpt.com")
        #expect(sessionCookie.path == "/")
        #expect(sessionCookie.value == "secret")
        #expect(sessionCookie.isSecure)
        #expect(sessionCookie.properties?[HTTPCookiePropertyKey("HttpOnly")] as? String == "TRUE")

        let deviceCookie = try #require(imported.last)
        #expect(deviceCookie.expiresDate == Date(timeIntervalSince1970: 1_776_000_000))
    }

    @Test
    func chatGPTCookiesRejectsPayloadWithoutSessionToken() {
        let cookies = [
            ChromeDevToolsCookie(
                name: "oai-did",
                value: "device-a",
                domain: ".chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: false,
                secure: true
            ),
            ChromeDevToolsCookie(
                name: "not-a-session-token",
                value: "noise",
                domain: ".chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: true,
                secure: true
            ),
        ]

        #expect(throws: ChatGPTAPIError.unauthorized) {
            _ = try ChromeCookieImporter.chatGPTHTTPCookies(from: cookies)
        }
    }

    @Test
    func chatGPTCookiesAcceptsChunkedSessionTokenCookies() throws {
        let cookies = [
            ChromeDevToolsCookie(
                name: "__Secure-next-auth.session-token.0",
                value: "chunk-a",
                domain: ".chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: true,
                secure: true
            ),
            ChromeDevToolsCookie(
                name: "__Secure-next-auth.session-token.1",
                value: "chunk-b",
                domain: ".chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: true,
                secure: true
            ),
            ChromeDevToolsCookie(
                name: "oai-did",
                value: "device-a",
                domain: ".chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: false,
                secure: true
            ),
        ]

        let imported = try ChromeCookieImporter.chatGPTHTTPCookies(from: cookies)

        #expect(imported.map(\.name) == [
            "__Secure-next-auth.session-token.0",
            "__Secure-next-auth.session-token.1",
            "oai-did",
        ])
    }

    @Test
    func storingSingleSessionCookieRemovesStaleChunks() async throws {
        let sessionStore = WebSessionStore(dataStore: .nonPersistent())
        await sessionStore.storeCookies(try [
            makeHTTPCookie(name: "__Secure-next-auth.session-token.0", value: "stale-a"),
            makeHTTPCookie(name: "__Secure-next-auth.session-token.1", value: "stale-b"),
        ])

        _ = try await ChromeCookieImporter.storeChatGPTCookies(
            from: [
                ChromeDevToolsCookie(
                    name: "__Secure-next-auth.session-token",
                    value: "fresh",
                    domain: ".chatgpt.com",
                    path: "/",
                    expires: nil,
                    httpOnly: true,
                    secure: true
                ),
            ],
            in: sessionStore
        )

        let cookies = await sessionStore.cookies(for: ChatGPTWebURLs.cookieScope)
        #expect(cookies.map(\.name) == ["__Secure-next-auth.session-token"])
        #expect(cookies.first?.value == "fresh")
    }

    @Test
    func storingChunkedSessionCookieRemovesStaleSingleCookie() async throws {
        let sessionStore = WebSessionStore(dataStore: .nonPersistent())
        await sessionStore.storeCookies(try [
            makeHTTPCookie(name: "__Secure-next-auth.session-token", value: "stale"),
        ])

        _ = try await ChromeCookieImporter.storeChatGPTCookies(
            from: [
                ChromeDevToolsCookie(
                    name: "__Secure-next-auth.session-token.0",
                    value: "fresh-a",
                    domain: ".chatgpt.com",
                    path: "/",
                    expires: nil,
                    httpOnly: true,
                    secure: true
                ),
                ChromeDevToolsCookie(
                    name: "__Secure-next-auth.session-token.1",
                    value: "fresh-b",
                    domain: ".chatgpt.com",
                    path: "/",
                    expires: nil,
                    httpOnly: true,
                    secure: true
                ),
            ],
            in: sessionStore
        )

        let cookies = await sessionStore.cookies(for: ChatGPTWebURLs.cookieScope)
        #expect(Set(cookies.map(\.name)) == [
            "__Secure-next-auth.session-token.0",
            "__Secure-next-auth.session-token.1",
        ])
        #expect(Set(cookies.map(\.value)) == ["fresh-a", "fresh-b"])
    }

    @Test
    func chatGPTCookiesRejectsFakeChunkedSessionTokenNames() {
        let cookies = [
            ChromeDevToolsCookie(
                name: "fake-session-token.0",
                value: "noise",
                domain: ".chatgpt.com",
                path: "/",
                expires: nil,
                httpOnly: true,
                secure: true
            ),
        ]

        #expect(throws: ChatGPTAPIError.unauthorized) {
            _ = try ChromeCookieImporter.chatGPTHTTPCookies(from: cookies)
        }
    }
}

private func makeHTTPCookie(name: String, value: String) throws -> HTTPCookie {
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
