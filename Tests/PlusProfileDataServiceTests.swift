import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct PlusProfileDataServiceTests {
    private let recovery: CloudBrowserSeedTestStorage

    init() throws { recovery = try CloudBrowserSeedTestStorage() }

    @Test func browserCaptureRequiresAuthenticatedProofAndDoesNotRefreshOrWriteCookies() async throws {
        let profile = sampleProfile(label: "arbitrary label", sortOrder: 0)
        let signIn = try CodexSignIn(data: CodexSignInFixture.data())
        let transport = makeRefreshTransport(usageAccountID: "workspace", catalogJSON: "{\"accounts\":{}}",
            sessionUser: "user", accessToken: signIn.accessToken)
        let runtime = PlusProfileRuntime(dataStore: .nonPersistent(), transport: transport)
        let service = PlusProfileDataService(runtimeProvider: StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime]),
            chromeSessionManager: StubChromeSessionManager(), browserSeeds: recovery.store)
        let cookie = try #require(HTTPCookie(properties: [.name: "__Secure-next-auth.session-token.0", .value: "synthetic-browser",
            .domain: "chatgpt.com", .path: "/api", .secure: "TRUE"]))
        await runtime.sessionStore.storeCookies([cookie])
        #expect(try await service.captureSavedSession(for: profile) == nil)
        _ = try await service.refreshProfile(profile)
        let before = await runtime.sessionStore.portableChatGPTCookies()
        let requests = transport.requestPaths
        let payload = try #require(try await service.captureSavedSession(for: profile))
        #expect(payload.kind == .browser)
        #expect(try payload.identity == .init(accountID: "workspace", userID: "user"))
        #expect(await runtime.sessionStore.portableChatGPTCookies() == before)
        #expect(transport.requestPaths == requests)
        let changed = try #require(HTTPCookie(properties: [.name: cookie.name, .value: "unverified-change",
            .domain: cookie.domain, .path: cookie.path, .secure: "TRUE"]))
        await runtime.sessionStore.storeCookies([changed])
        #expect(try await service.captureSavedSession(for: profile) == nil)
        #expect(transport.requestPaths == requests)
    }

    @Test
    func selectorUsesOneCatalogFetchAndDoesNotRetimestampFailedEntitlement() async throws {
        var profile = sampleProfile(label: "selector", sortOrder: 0)
        profile.openCodeOpenAIAccount = OpenCodeOpenAIIdentity(accountID: "account-a", userID: "user-a", email: "unused@example.test")
        let transport = makeRefreshTransport(usageAccountID: "account-a", catalogJSON: """
            {"accounts":{"account-a":{"account":{"account_id":"account-a","is_deactivated":false},
            "can_access_with_session":true,"entitlement":{"expires_at":"2027-06-01T00:00:00Z","has_active_subscription":true}}}}
            """, sessionUser: "user-a", failCatalogAfterFirst: true)
        let runtime = PlusProfileRuntime(dataStore: .nonPersistent(), transport: transport)
        let service = PlusProfileDataService(runtimeProvider: StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime]),
            chromeSessionManager: StubChromeSessionManager(), browserSeeds: recovery.store)
        let first = try await service.refreshProfile(profile)
        let observation = try #require(first.selectorObservation)
        let entitlement = try #require(observation.entitlement)
        #expect(observation.usage?.observedAt == first.usage.fetchedAt)
        #expect(entitlement.observedAt >= first.usage.fetchedAt)
        #expect(transport.requestPaths.filter { $0.contains("accounts/check") }.count == 1)
        let second = try await service.refreshProfile(profile)
        #expect(second.selectorObservation?.usage != nil)
        #expect(second.selectorObservation?.entitlement == nil)
        #expect(second.selectorObservation?.unavailableReasons.contains("expiry-refresh-failed") == true)
        #expect(second.expiryRefresh == .unchanged)
        #expect(first.selectorObservation?.entitlement?.observedAt == entitlement.observedAt)
    }

    @Test
    func refreshWithDefaultStorageLayoutFetchesSessionThenUsageAndExpiry() async throws {
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case "/api/auth/session":
                return HTTPResponseData(
                    data: Data(
                        """
                        {
                          "accessToken": "token-alpha",
                          "account": {
                            "id": "acct_alpha_123456"
                          },
                          "expires": "2026-05-01T10:00:00Z",
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
            case "/codex/cloud/settings/analytics":
                return HTTPResponseData(
                    data: Data(
                        """
                        <html data-build="web-2026.04.20">
                          <body>
                            <script id="client-bootstrap" type="application/json">
                              {
                                "authStatus": "logged_in",
                                "session": {
                                  "accessToken": "token-alpha",
                                  "expires": "2026-05-01T10:00:00Z",
                                  "account": {
                                    "id": "acct_alpha_123456"
                                  }
                                },
                                "locale": "en-US"
                              }
                            </script>
                          </body>
                        </html>
                        """.utf8
                    ),
                    response: HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                )
            case "/backend-api/wham/usage":
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "acct_alpha_123456")
                return HTTPResponseData(
                    data: Data(
                        """
                        {
                          "account_id": "acct_alpha_123456",
                          "plan_type": "chatgpt_plus",
                          "rate_limit": {
                            "allowed": true,
                            "limit_reached": false,
                            "primary_window": {
                              "used_percent": 36,
                              "limit_window_seconds": 18000,
                              "reset_after_seconds": 900,
                              "reset_at": 1776000900
                            },
                            "secondary_window": {
                              "used_percent": 18,
                              "limit_window_seconds": 604800,
                              "reset_after_seconds": 86400,
                              "reset_at": 1776086400
                            }
                          }
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
            case "/backend-api/accounts/check/v4-2023-04-27":
                return HTTPResponseData(
                    data: Data(
                        """
                        {
                          "accounts": {
                            "acct_alpha_123456": {
                              "account": {
                                "id": "acct_alpha_123456",
                                "name": "Alpha",
                                "plan_type": "chatgpt_plus"
                              },
                              "entitlement": {
                                "expires_at": "2026-05-18T10:00:00Z",
                                "has_active_subscription": true
                              }
                            }
                          }
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
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }

        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider, browserSeeds: recovery.store)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == "acct_alpha_123456")
        #expect(result.usage.planType == "chatgpt_plus")
        #expect(result.usage.primaryWindow.remainingPercent == 64)
        #expect(result.usage.secondaryWindow?.remainingPercent == 82)
        #expect(result.detectedNote == "Chatgpt Plus · 123456")
        #expect(result.expiryRefresh == .value(isoDate("2026-05-18T10:00:00Z")))
        #expect(
            transport.requestPaths
                == [
                    "/api/auth/session",
                    "/codex/cloud/settings/analytics",
                    "/backend-api/wham/usage",
                    "/backend-api/accounts/check/v4-2023-04-27",
                ]
        )
    }

    @Test
    func refreshProfileMatchesExpiryByCatalogOwnerAlias() async throws {
        let profile = sampleProfile(label: "owner@example.com", sortOrder: 0)
        let transport = makeRefreshTransport(
            usageAccountID: "user-owner-alpha",
            catalogJSON:
                """
                {
                  "account_ordering": ["11111111-2222-4333-8444-555555555555"],
                  "accounts": {
                    "11111111-2222-4333-8444-555555555555": {
                      "account": {
                        "account_id": "11111111-2222-4333-8444-555555555555",
                        "account_user_id": "user-owner-alpha__11111111-2222-4333-8444-555555555555",
                        "account_owner_id": "user-owner-alpha",
                        "plan_type": "plus"
                      },
                      "entitlement": {
                        "expires_at": "2026-05-17T13:42:54+00:00",
                        "has_active_subscription": true
                      }
                    },
                    "default": {
                      "account": {
                        "account_id": "11111111-2222-4333-8444-555555555555",
                        "account_user_id": "user-owner-alpha__11111111-2222-4333-8444-555555555555",
                        "account_owner_id": "user-owner-alpha",
                        "plan_type": "plus"
                      },
                      "entitlement": {
                        "expires_at": "2026-05-17T13:42:54+00:00",
                        "has_active_subscription": true
                      }
                    }
                  }
                }
                """
        )
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider, browserSeeds: recovery.store)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == "user-owner-alpha")
        #expect(result.expiryRefresh == .value(isoDate("2026-05-17T13:42:54+00:00")))
    }

    @Test
    func refreshProfileFallsBackToDefaultCatalogExpiryWhenUsageAccountDoesNotMatchAliases() async throws {
        var profile = sampleProfile(label: "default@example.com", sortOrder: 0)
        profile.openCodeOpenAIAccount = OpenCodeOpenAIIdentity(accountID: "user-not-listed-in-catalog", userID: "user-a", email: "unused@example.test")
        let transport = makeRefreshTransport(
            usageAccountID: "user-not-listed-in-catalog",
            catalogJSON:
                """
                {
                  "accounts": {
                    "default": {
                      "account": {
                        "account_id": "11111111-2222-4333-8444-555555555555",
                        "account_owner_id": "user-owner-alpha",
                        "plan_type": "plus"
                      },
                      "entitlement": {
                        "expires_at": "2026-05-17T13:42:54+00:00",
                        "has_active_subscription": true
                      }
                    }
                  }
                }
                """,
            sessionUser: "user-a"
        )
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider, browserSeeds: recovery.store)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == "user-not-listed-in-catalog")
        #expect(result.expiryRefresh == .value(isoDate("2026-05-17T13:42:54+00:00")))
        #expect(result.selectorObservation?.entitlement == nil)
        #expect(result.selectorObservation?.usage != nil)
        #expect(result.selectorObservation?.unavailableReasons.contains("expiry-unknown") == true)
    }

    @Test
    func syncChromeSessionImportsCookiesAndValidatesCurrentSession() async throws {
        let profile = sampleProfile(label: "chrome@example.com", sortOrder: 0)
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case "/api/auth/session":
                return HTTPResponseData(
                    data: Data(
                        """
                        {
                          "accessToken": "token-chrome",
                          "account": {
                            "id": "acct_chrome_123456"
                          },
                          "expires": "2026-05-01T10:00:00Z",
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
            case "/codex/cloud/settings/analytics":
                return HTTPResponseData(
                    data: Data(
                        """
                        <html data-build="web-2026.04.20">
                          <body>
                            <script id="client-bootstrap" type="application/json">
                              {
                                "authStatus": "logged_in",
                                "session": {
                                  "accessToken": "token-chrome",
                                  "expires": "2026-05-01T10:00:00Z",
                                  "account": {
                                    "id": "acct_chrome_123456"
                                  }
                                },
                                "locale": "en-US"
                              }
                            </script>
                          </body>
                        </html>
                        """.utf8
                    ),
                    response: HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                )
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager(
            cookies: [
                ChromeDevToolsCookie(
                    name: "__Secure-next-auth.session-token",
                    value: "session-a",
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
        )
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager,
            browserSeeds: recovery.store
        )

        try await service.syncChromeSession(for: profile)
        let context = try #require(runtime.authContext)

        #expect(chromeSessionManager.syncedProfileIDs == [profile.id])
        #expect(context.accountID == "acct_chrome_123456")
        #expect(context.deviceID == "device-a")
        #expect(runtime.authContext == context)
        #expect(await runtime.sessionStore.cookieValue(named: "oai-did") == "device-a")
    }

    @Test
    func syncChromeSessionReopensChromeWhenValidationRejectsImportedCookies() async throws {
        let profile = sampleProfile(label: "retry@example.com", sortOrder: 0)
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case "/api/auth/session":
                return HTTPResponseData(
                    data: Data("{}".utf8),
                    response: HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [:]
                    )!
                )
            case "/codex/cloud/settings/analytics":
                return HTTPResponseData(
                    data: Data(
                        """
                        <html data-build="web-2026.04.20">
                          <body>
                            <script id="client-bootstrap" type="application/json">
                              {
                                "authStatus": "logged_out"
                              }
                            </script>
                          </body>
                        </html>
                        """.utf8
                    ),
                    response: HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                )
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager(
            cookies: [
                ChromeDevToolsCookie(
                    name: "__Secure-next-auth.session-token",
                    value: "stale-session",
                    domain: ".chatgpt.com",
                    path: "/",
                    expires: nil,
                    httpOnly: true,
                    secure: true
                ),
            ]
        )
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager,
            browserSeeds: recovery.store
        )

        await #expect(throws: ChatGPTAPIError.unauthorized) {
            try await service.syncChromeSession(for: profile)
        }
        #expect(chromeSessionManager.syncedProfileIDs == [profile.id])
        #expect(chromeSessionManager.openedProfileIDs == [profile.id])
    }

    @Test
    func clearSessionClearsNativeCookiesAndChromeCookies() async throws {
        let profile = sampleProfile(
            label: "clear@example.com",
            sortOrder: 0,
            provider: .codex
        )
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent()
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager()
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager,
            browserSeeds: recovery.store
        )

        try await service.clearSession(for: profile)

        #expect(provider.clearedProfileIDs == [profile.id])
        #expect(chromeSessionManager.clearedProfileIDs == [profile.id])
        #expect(runtime.authContext == nil)
    }

    @Test
    func openChromePasskeySetupDelegatesToChromeSessionManager() async throws {
        let profile = sampleProfile(label: "touchid@example.com", sortOrder: 0)
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent()
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager()
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager,
            browserSeeds: recovery.store
        )

        try await service.openChromePasskeySetup(for: profile)

        #expect(chromeSessionManager.openedPasskeySetupProfileIDs == [profile.id])
    }

    @Test
    func openChromeAccountPageDelegatesToChromeSessionManager() async throws {
        let profile = sampleProfile(label: "open@example.com", sortOrder: 0)
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent()
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager()
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager,
            browserSeeds: recovery.store
        )

        try await service.openChromeAccountPage(for: profile)

        #expect(chromeSessionManager.openedAccountPageProfileIDs == [profile.id])
    }

    @Test
    func removeProfileDataRemovesNativeDataAndDedicatedChromeProfile() async throws {
        let profile = sampleProfile(label: "remove@example.com", sortOrder: 0)
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent()
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager()
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager,
            browserSeeds: recovery.store
        )

        try await service.removeProfileData(for: profile)

        #expect(provider.removedProfileIDs == [profile.id])
        #expect(chromeSessionManager.removedProfileIDs == [profile.id])
    }
}

@MainActor
private final class StubRuntimeProvider: PlusProfileRuntimeProviding {
    private let runtimeByProfileID: [UUID: PlusProfileRuntime]
    private(set) var clearedProfileIDs: [UUID] = []
    private(set) var removedProfileIDs: [UUID] = []

    init(runtimeByProfileID: [UUID: PlusProfileRuntime]) {
        self.runtimeByProfileID = runtimeByProfileID
    }

    func runtime(for profile: PlusProfile) -> PlusProfileRuntime {
        runtimeByProfileID[profile.id] ?? PlusProfileRuntime(
            dataStore: .nonPersistent()
        )
    }

    func clearSession(for profile: PlusProfile) async {
        clearedProfileIDs.append(profile.id)
        await runtime(for: profile).sessionStore.clear()
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        removedProfileIDs.append(profile.id)
    }
}

@MainActor
private final class StubChromeSessionManager: ChromeSessionManaging {
    private let cookies: [ChromeDevToolsCookie]
    private(set) var openedAccountPageProfileIDs: [UUID] = []
    private(set) var openedProfileIDs: [UUID] = []
    private(set) var openedPasskeySetupProfileIDs: [UUID] = []
    private(set) var syncedProfileIDs: [UUID] = []
    private(set) var clearedProfileIDs: [UUID] = []
    private(set) var removedProfileIDs: [UUID] = []
    private(set) var closedProfileIDs: [UUID] = []

    init(cookies: [ChromeDevToolsCookie] = []) {
        self.cookies = cookies
    }

    func openAccountPage(for profile: PlusProfile) async throws {
        openedAccountPageProfileIDs.append(profile.id)
    }

    func openSignIn(for profile: PlusProfile) async throws {
        openedProfileIDs.append(profile.id)
    }

    func openPasskeySetup(for profile: PlusProfile) async throws {
        openedPasskeySetupProfileIDs.append(profile.id)
    }

    func syncCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult {
        syncedProfileIDs.append(profile.id)
        let count = try await ChromeCookieImporter.storeCookies(
            from: cookies,
            for: profile.provider,
            in: sessionStore
        )
        return ChromeCookieImportResult(importedCookieCount: count)
    }

    func waitForSignInToFinish(for profile: PlusProfile) async -> Bool {
        false
    }

    func clearCookies(for profile: PlusProfile) async throws {
        clearedProfileIDs.append(profile.id)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        removedProfileIDs.append(profile.id)
    }

    func closeSignIn(for profile: PlusProfile) async {
        closedProfileIDs.append(profile.id)
    }
}

@MainActor
private final class MockHTTPTransport: HTTPTransport {
    private let handler: @Sendable (URLRequest) async throws -> HTTPResponseData
    private(set) var requestPaths: [String] = []

    init(handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponseData) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        requestPaths.append(request.url?.path ?? "<missing>")
        return try await handler(request)
    }
}

@MainActor
private func makeRefreshTransport(
    usageAccountID: String,
    catalogJSON: String,
    sessionUser: String? = nil,
    failCatalogAfterFirst: Bool = false,
    accessToken: String = "token-alpha"
) -> MockHTTPTransport {
    let counter = RequestCounter()
    return MockHTTPTransport { request in
        switch request.url?.path {
        case "/api/auth/session":
            return HTTPResponseData(
                data: Data(
                    """
                    {
                      "accessToken": "\(accessToken)",
                      "user": {"id": "\(sessionUser ?? "")"},
                      "account": {
                        "id": "\(usageAccountID)"
                      },
                      "expires": "2026-05-01T10:00:00Z",
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
        case "/codex/cloud/settings/analytics":
            return HTTPResponseData(
                data: Data(
                    """
                    <html data-build="web-2026.04.20">
                      <body>
                        <script id="client-bootstrap" type="application/json">
                          {
                            "authStatus": "logged_in",
                            "session": {
                              "accessToken": "\(accessToken)",
                              "expires": "2026-05-01T10:00:00Z",
                              "account": {
                                "id": "\(usageAccountID)"
                              }
                            },
                            "locale": "en-US"
                          }
                        </script>
                      </body>
                    </html>
                    """.utf8
                ),
                response: HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
            )
        case "/backend-api/wham/usage":
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == usageAccountID)
            return HTTPResponseData(
                data: Data(
                    """
                    {
                      "account_id": "\(usageAccountID)",
                      "plan_type": "chatgpt_plus",
                      "rate_limit": {
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": {
                          "used_percent": 36,
                          "limit_window_seconds": 18000,
                          "reset_after_seconds": 900,
                          "reset_at": 1776000900
                        },
                        "secondary_window": {
                          "used_percent": 18,
                          "limit_window_seconds": 604800,
                          "reset_after_seconds": 86400,
                          "reset_at": 1776086400
                        }
                      }
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
        case "/backend-api/accounts/check/v4-2023-04-27":
            if failCatalogAfterFirst, await counter.next() > 1 { throw ChatGPTAPIError.invalidResponse }
            return HTTPResponseData(
                data: Data(catalogJSON.utf8),
                response: HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )
        default:
            throw ChatGPTAPIError.invalidResponse
        }
    }
}

private actor RequestCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private func sampleProfile(
    label: String,
    sortOrder: Int,
    provider: ProfileProvider = .codex
) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        provider: provider,
        label: label,
        emailLink: nil,
        detectedNote: nil,
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}
