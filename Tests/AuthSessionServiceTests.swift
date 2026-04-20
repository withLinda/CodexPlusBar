import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

struct AuthSessionServiceTests {
    @Test
    func decodesCurrentSessionWithBootstrapMetadata() throws {
        let data = Data(
            """
            {
              "accessToken": "token-alpha",
              "expires": "2026-06-16T03:28:00Z",
              "account": {
                "id": "workspace-a"
              },
              "locale": "en-US"
            }
            """.utf8
        )
        let bootstrap = ChatGPTWebBootstrap(
            authStatus: "logged_in",
            accessToken: "bootstrap-token",
            accountID: "workspace-a",
            expiresAt: nil,
            clientVersion: "prod-build-123",
            locale: "en-US"
        )

        let context = try AuthSessionService.decodeAuthContext(
            from: data,
            bootstrap: bootstrap,
            deviceID: "device-123"
        )

        #expect(context.accessToken == "token-alpha")
        #expect(context.accountID == "workspace-a")
        #expect(context.clientVersion == "prod-build-123")
        #expect(context.deviceID == "device-123")
        #expect(context.language == "en-US")
    }

    @Test
    func fallsBackToBootstrapWhenSessionPayloadIsSparse() throws {
        let bootstrap = ChatGPTWebBootstrap(
            authStatus: "logged_in",
            accessToken: "bootstrap-token",
            accountID: "workspace-b",
            expiresAt: Date(timeIntervalSince1970: 1_773_819_260),
            clientVersion: "prod-build-456",
            locale: "en-US"
        )

        let context = try AuthSessionService.decodeAuthContext(
            from: Data("{}".utf8),
            bootstrap: bootstrap,
            deviceID: "device-456"
        )

        #expect(context.accessToken == "bootstrap-token")
        #expect(context.accountID == "workspace-b")
        #expect(context.clientVersion == "prod-build-456")
    }

    @Test
    func loggedOutBootstrapIsUnauthorized() {
        let bootstrap = ChatGPTWebBootstrap(
            authStatus: "logged_out",
            accessToken: nil,
            accountID: nil,
            expiresAt: nil,
            clientVersion: "prod-build-456",
            locale: "en-US"
        )

        do {
            _ = try AuthSessionService.decodeAuthContext(from: Data("{}".utf8), bootstrap: bootstrap)
            Issue.record("Expected an unauthorized error.")
        } catch let error as ChatGPTAPIError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Expected ChatGPTAPIError.unauthorized, got \(error).")
        }
    }

    @Test
    func missingAccessTokenWithoutFallbackIsUnauthorized() {
        do {
            _ = try AuthSessionService.decodeAuthContext(from: Data("{}".utf8))
            Issue.record("Expected an unauthorized error.")
        } catch let error as ChatGPTAPIError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Expected ChatGPTAPIError.unauthorized, got \(error).")
        }
    }

    @Test
    func bootstrapWithoutSessionDataIsUnauthorized() {
        let bootstrap = ChatGPTWebBootstrap(
            authStatus: nil,
            accessToken: nil,
            accountID: nil,
            expiresAt: nil,
            clientVersion: "prod-build-456",
            locale: "en-US"
        )

        do {
            _ = try AuthSessionService.decodeAuthContext(from: Data("{}".utf8), bootstrap: bootstrap)
            Issue.record("Expected an unauthorized error.")
        } catch let error as ChatGPTAPIError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Expected ChatGPTAPIError.unauthorized, got \(error).")
        }
    }

    @Test
    @MainActor
    func switchWorkspaceRejectsMismatchedSessionAccount() async throws {
        let transport = AuthSessionRecordingTransport()
        let sessionStore = WebSessionStore(dataStore: .nonPersistent())
        transport.enqueue { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(url.path == "/api/auth/session")
            #expect(components.queryItems?.contains(where: { $0.name == "exchange_workspace_token" && $0.value == "true" }) == true)
            #expect(components.queryItems?.contains(where: { $0.name == "workspace_id" && $0.value == "workspace-b" }) == true)
            #expect(await sessionStore.currentAccountCookieValue() == "workspace-b")

            return HTTPResponseData(
                data: Data(
                    """
                    {
                      "accessToken": "token-alpha",
                      "account": {
                        "id": "workspace-a"
                      }
                    }
                    """.utf8
                ),
                response: HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )
        }

        let service = AuthSessionService(
            transport: transport,
            sessionStore: sessionStore
        )

        do {
            _ = try await service.switchWorkspaceAndRefreshSession(workspaceID: "workspace-b")
            Issue.record("Expected a switch mismatch error.")
        } catch let error as ChatGPTAPIError {
            #expect(
                error ==
                    .unsupported(
                        "ChatGPT kept the active session on account workspace-a while the app tried to switch to workspace-b."
                    )
            )
        } catch {
            Issue.record("Expected ChatGPTAPIError.unsupported, got \(error).")
        }
    }

    @Test
    @MainActor
    func switchWorkspaceFallsBackToCurrentSessionAfterSparseSwitchResponse() async throws {
        let transport = AuthSessionRecordingTransport()
        let sessionStore = WebSessionStore(dataStore: .nonPersistent())
        let fallback = ChatGPTAuthContext(
            accessToken: "token-alpha",
            accountID: "workspace-a",
            expiresAt: nil,
            deviceID: "device-123",
            clientVersion: "prod-build-123",
            language: "en-US"
        )

        transport.enqueue { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(url.path == "/api/auth/session")
            #expect(components.queryItems?.contains(where: { $0.name == "exchange_workspace_token" && $0.value == "true" }) == true)
            #expect(components.queryItems?.contains(where: { $0.name == "workspace_id" && $0.value == "workspace-b" }) == true)
            #expect(await sessionStore.currentAccountCookieValue() == "workspace-b")

            return HTTPResponseData(
                data: Data("{}".utf8),
                response: HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )
        }
        transport.enqueue { request in
            #expect(request.url?.path == "/api/auth/session")
            #expect(await sessionStore.currentAccountCookieValue() == "workspace-b")
            return HTTPResponseData(
                data: Data(
                    """
                    {
                      "accessToken": "token-bravo",
                      "account": {
                        "id": "workspace-b"
                      },
                      "locale": "en-US"
                    }
                    """.utf8
                ),
                response: HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )
        }

        let service = AuthSessionService(
            transport: transport,
            sessionStore: sessionStore
        )

        let context = try await service.switchWorkspaceAndRefreshSession(
            workspaceID: "workspace-b",
            fallback: fallback
        )

        #expect(context.accountID == "workspace-b")
        #expect(context.accessToken == "token-bravo")
        #expect(context.clientVersion == "prod-build-123")
        #expect(await sessionStore.currentAccountCookieValue() == "workspace-b")
    }

    @Test
    func makeWorkspaceSwitchRequestAppliesExplicitTimeoutInterval() {
        let request = AuthSessionService.makeWorkspaceSwitchRequest(
            workspaceID: "workspace-a",
            timeoutInterval: 95
        )

        #expect(request.timeoutInterval == 95)
    }
}

@MainActor
private final class AuthSessionRecordingTransport: HTTPTransport {
    private var responders: [(URLRequest) async throws -> HTTPResponseData] = []

    func enqueue(_ responder: @escaping (URLRequest) async throws -> HTTPResponseData) {
        responders.append(responder)
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        guard responders.isEmpty == false else {
            throw ChatGPTAPIError.httpStatus(500)
        }

        return try await responders.removeFirst()(request)
    }
}

@MainActor
struct WebSessionStoreTests {
    @Test
    func updatesExistingAccountCookieWithoutChangingCoreProperties() async throws {
        let store = WebSessionStore(dataStore: .nonPersistent())
        let originalCookie = try #require(
            HTTPCookie(
                properties: [
                    .domain: "chatgpt.com",
                    .path: "/",
                    .name: "_account",
                    .value: "workspace-a",
                    .secure: "TRUE",
                ]
            )
        )

        await store.storeCookies([originalCookie])
        try await store.setCurrentAccountCookie("workspace-b")

        let updatedCookie = try await requireCurrentAccountCookie(in: store)
        let matchingCookies = await store.cookies(for: ChatGPTWebURLs.cookieScope).filter { $0.name == "_account" }

        #expect(updatedCookie.value == "workspace-b")
        #expect(updatedCookie.domain == "chatgpt.com")
        #expect(updatedCookie.path == "/")
        #expect(updatedCookie.isSecure)
        #expect(matchingCookies.count == 1)
    }

    @Test
    func createsSecureSessionAccountCookieWhenMissing() async throws {
        let store = WebSessionStore(dataStore: .nonPersistent())

        try await store.setCurrentAccountCookie("workspace-c")

        let cookie = try await requireCurrentAccountCookie(in: store)

        #expect(cookie.value == "workspace-c")
        #expect(cookie.domain == "chatgpt.com")
        #expect(cookie.path == "/")
        #expect(cookie.isSecure)
        #expect(cookie.expiresDate == nil)
    }
}

@MainActor
private func requireCurrentAccountCookie(in store: WebSessionStore) async throws -> HTTPCookie {
    let cookies = await store.cookies(for: ChatGPTWebURLs.cookieScope)
    return try #require(cookies.first { $0.name == "_account" })
}
