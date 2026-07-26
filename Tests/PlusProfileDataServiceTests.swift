import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct PlusProfileDataServiceTests {
    @Test
    func refreshProfileFetchesSessionThenUsageAndExpiryAndBuildsDetectedNote() async throws {
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
        let service = PlusProfileDataService(runtimeProvider: provider)

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

    @Test(.tags(.networking))
    func refreshClaudeProfileDiscoversOrganizationThenCachesIt() async throws {
        let organizationID = "841724c1-1111-4222-8333-123456789abc"
        let profile = sampleProfile(
            label: "claude@example.com",
            sortOrder: 0,
            provider: .claude
        )
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "GET")

            switch request.url?.path {
            case ClaudeWebURLs.bootstrapEndpoint.path:
                return try makeClaudeBootstrapResponse(
                    for: request,
                    organizationIDs: [organizationID]
                )
            case "/api/organizations/\(organizationID)/usage":
                return try makeClaudeUsageResponse(for: request, usedPercent: 2)
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider)

        let result = try await service.refreshProfile(profile)
        _ = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == organizationID)
        #expect(result.usage.planType == "claude")
        #expect(result.usage.primaryWindow.usedPercent == 2)
        #expect(result.usage.primaryWindow.remainingPercent == 98)
        #expect(result.usage.secondaryWindow == nil)
        #expect(result.detectedNote == "Claude")
        #expect(result.expiryRefresh == .unchanged)
        #expect(
            transport.requestPaths
                == [
                    "/edge-api/bootstrap",
                    "/api/organizations/\(organizationID)/usage",
                    "/api/organizations/\(organizationID)/usage",
                ]
        )
        #expect(runtime.authContext == nil)
        #expect(runtime.claudeOrganizationID == organizationID)
    }

    @Test(.tags(.networking))
    func refreshClaudeProfileRestoresSavedChromeCookiesAfterUnauthorized() async throws {
        let organizationID = "841724c1-1111-4222-8333-123456789abc"
        let profile = sampleProfile(
            label: "claude-restored@example.com",
            sortOrder: 0,
            provider: .claude
        )
        let bootstrapAttempts = RequestCounter()
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case ClaudeWebURLs.bootstrapEndpoint.path:
                if await bootstrapAttempts.next() == 1 {
                    throw ChatGPTAPIError.unauthorized
                }
                return try makeClaudeBootstrapResponse(
                    for: request,
                    organizationIDs: [organizationID]
                )
            case "/api/organizations/\(organizationID)/usage":
                return try makeClaudeUsageResponse(for: request, usedPercent: 9)
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
                    name: "sessionKey",
                    value: "saved-claude-session",
                    domain: ".claude.ai",
                    path: "/",
                    expires: nil,
                    httpOnly: true,
                    secure: true
                ),
            ]
        )
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager
        )

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == organizationID)
        #expect(result.usage.primaryWindow.usedPercent == 9)
        #expect(chromeSessionManager.restoredProfileIDs == [profile.id])
        #expect(chromeSessionManager.syncedProfileIDs.isEmpty)
        #expect(
            await runtime.sessionStore.cookieValue(
                named: "sessionKey",
                for: ClaudeWebURLs.cookieScope
            ) == "saved-claude-session"
        )
        #expect(
            transport.requestPaths
                == [
                    "/edge-api/bootstrap",
                    "/edge-api/bootstrap",
                    "/api/organizations/\(organizationID)/usage",
                ]
        )
    }

    @Test(.tags(.networking))
    func refreshClaudeProfilePrefersLastActiveOrganizationCookie() async throws {
        let firstOrganizationID = "11111111-2222-4333-8444-555555555555"
        let activeOrganizationID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let profile = sampleProfile(
            label: "claude-multi@example.com",
            sortOrder: 0,
            provider: .claude
        )
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case ClaudeWebURLs.bootstrapEndpoint.path:
                return try makeClaudeBootstrapResponse(
                    for: request,
                    organizationIDs: [firstOrganizationID, activeOrganizationID]
                )
            case "/api/organizations/\(activeOrganizationID)/usage":
                return try makeClaudeUsageResponse(for: request, usedPercent: 12)
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        await runtime.sessionStore.storeCookies([
            try makeClaudeCookie(
                name: ClaudeBootstrapService.lastActiveOrganizationCookieName,
                value: activeOrganizationID
            ),
        ])
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == activeOrganizationID)
        #expect(result.usage.primaryWindow.usedPercent == 12)
        #expect(
            transport.requestPaths
                == [
                    "/edge-api/bootstrap",
                    "/api/organizations/\(activeOrganizationID)/usage",
                ]
        )
    }

    @Test(.tags(.networking))
    func refreshClaudeProfileTriesNextMembershipAfterUsage404() async throws {
        let firstOrganizationID = "11111111-2222-4333-8444-555555555555"
        let workingOrganizationID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let profile = sampleProfile(
            label: "claude-fallback@example.com",
            sortOrder: 0,
            provider: .claude
        )
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case ClaudeWebURLs.bootstrapEndpoint.path:
                return try makeClaudeBootstrapResponse(
                    for: request,
                    organizationIDs: [firstOrganizationID, workingOrganizationID]
                )
            case "/api/organizations/\(firstOrganizationID)/usage":
                throw ChatGPTAPIError.httpStatus(404)
            case "/api/organizations/\(workingOrganizationID)/usage":
                return try makeClaudeUsageResponse(for: request, usedPercent: 18)
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == workingOrganizationID)
        #expect(runtime.claudeOrganizationID == workingOrganizationID)
        #expect(
            transport.requestPaths
                == [
                    "/edge-api/bootstrap",
                    "/api/organizations/\(firstOrganizationID)/usage",
                    "/api/organizations/\(workingOrganizationID)/usage",
                ]
        )
    }

    @Test(.tags(.networking))
    func cachedClaudeOrganization404ForcesBootstrapRediscovery() async throws {
        let staleOrganizationID = "11111111-2222-4333-8444-555555555555"
        let freshOrganizationID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let profile = sampleProfile(
            label: "claude-stale@example.com",
            sortOrder: 0,
            provider: .claude
        )
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case "/api/organizations/\(staleOrganizationID)/usage":
                throw ChatGPTAPIError.httpStatus(404)
            case ClaudeWebURLs.bootstrapEndpoint.path:
                return try makeClaudeBootstrapResponse(
                    for: request,
                    organizationIDs: [freshOrganizationID]
                )
            case "/api/organizations/\(freshOrganizationID)/usage":
                return try makeClaudeUsageResponse(for: request, usedPercent: 23)
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        runtime.updateClaudeOrganizationID(staleOrganizationID)
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == freshOrganizationID)
        #expect(runtime.claudeOrganizationID == freshOrganizationID)
        #expect(
            transport.requestPaths
                == [
                    "/api/organizations/\(staleOrganizationID)/usage",
                    "/edge-api/bootstrap",
                    "/api/organizations/\(freshOrganizationID)/usage",
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
        let service = PlusProfileDataService(runtimeProvider: provider)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == "user-owner-alpha")
        #expect(result.expiryRefresh == .value(isoDate("2026-05-17T13:42:54+00:00")))
    }

    @Test
    func refreshProfileFallsBackToDefaultCatalogExpiryWhenUsageAccountDoesNotMatchAliases() async throws {
        let profile = sampleProfile(label: "default@example.com", sortOrder: 0)
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
                """
        )
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == "user-not-listed-in-catalog")
        #expect(result.expiryRefresh == .value(isoDate("2026-05-17T13:42:54+00:00")))
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
            chromeSessionManager: chromeSessionManager
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
            chromeSessionManager: chromeSessionManager
        )

        await #expect(throws: ChatGPTAPIError.unauthorized) {
            try await service.syncChromeSession(for: profile)
        }
        #expect(chromeSessionManager.syncedProfileIDs == [profile.id])
        #expect(chromeSessionManager.openedProfileIDs == [profile.id])
    }

    @Test(.tags(.networking))
    func syncClaudeSessionImportsCookiesAndValidatesUsage() async throws {
        let staleOrganizationID = "11111111-2222-4333-8444-555555555555"
        let organizationID = "841724c1-1111-4222-8333-123456789abc"
        let profile = sampleProfile(
            label: "claude-sync@example.com",
            sortOrder: 0,
            provider: .claude
        )
        let transport = MockHTTPTransport { request in
            switch request.url?.path {
            case ClaudeWebURLs.bootstrapEndpoint.path:
                return try makeClaudeBootstrapResponse(
                    for: request,
                    organizationIDs: [organizationID]
                )
            case "/api/organizations/\(organizationID)/usage":
                return try makeClaudeUsageResponse(for: request, usedPercent: 7)
            default:
                throw ChatGPTAPIError.invalidResponse
            }
        }
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent(),
            transport: transport
        )
        runtime.updateClaudeOrganizationID(staleOrganizationID)
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager(
            cookies: [
                ChromeDevToolsCookie(
                    name: "sessionKey",
                    value: "claude-session",
                    domain: ".claude.ai",
                    path: "/",
                    expires: nil,
                    httpOnly: true,
                    secure: true
                ),
                ChromeDevToolsCookie(
                    name: ClaudeBootstrapService.lastActiveOrganizationCookieName,
                    value: organizationID,
                    domain: ".claude.ai",
                    path: "/",
                    expires: nil,
                    httpOnly: false,
                    secure: true
                ),
            ]
        )
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager
        )

        try await service.syncChromeSession(for: profile)

        #expect(chromeSessionManager.syncedProfileIDs == [profile.id])
        #expect(chromeSessionManager.closedProfileIDs == [profile.id])
        #expect(runtime.authContext == nil)
        #expect(runtime.claudeOrganizationID == organizationID)
        #expect(
            transport.requestPaths
                == [
                    "/edge-api/bootstrap",
                    "/api/organizations/\(organizationID)/usage",
                ]
        )
        #expect(
            await runtime.sessionStore.cookieValue(
                named: "sessionKey",
                for: ClaudeWebURLs.cookieScope
            ) == "claude-session"
        )
    }

    @Test
    func clearSessionClearsNativeCookiesAndChromeCookies() async throws {
        let profile = sampleProfile(
            label: "clear@example.com",
            sortOrder: 0,
            provider: .claude
        )
        let runtime = PlusProfileRuntime(
            dataStore: .nonPersistent()
        )
        runtime.updateClaudeOrganizationID(
            "841724c1-1111-4222-8333-123456789abc"
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let chromeSessionManager = StubChromeSessionManager()
        let service = PlusProfileDataService(
            runtimeProvider: provider,
            chromeSessionManager: chromeSessionManager
        )

        try await service.clearSession(for: profile)

        #expect(provider.clearedProfileIDs == [profile.id])
        #expect(chromeSessionManager.clearedProfileIDs == [profile.id])
        #expect(runtime.claudeOrganizationID == nil)
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
            chromeSessionManager: chromeSessionManager
        )

        try await service.openChromePasskeySetup(for: profile)

        #expect(chromeSessionManager.openedPasskeySetupProfileIDs == [profile.id])
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
            chromeSessionManager: chromeSessionManager
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
    private(set) var openedProfileIDs: [UUID] = []
    private(set) var openedPasskeySetupProfileIDs: [UUID] = []
    private(set) var syncedProfileIDs: [UUID] = []
    private(set) var restoredProfileIDs: [UUID] = []
    private(set) var clearedProfileIDs: [UUID] = []
    private(set) var removedProfileIDs: [UUID] = []
    private(set) var closedProfileIDs: [UUID] = []

    init(cookies: [ChromeDevToolsCookie] = []) {
        self.cookies = cookies
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

    func restoreCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult {
        restoredProfileIDs.append(profile.id)
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

private actor RequestCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private func makeClaudeBootstrapResponse(
    for request: URLRequest,
    organizationIDs: [String]
) throws -> HTTPResponseData {
    let memberships = organizationIDs
        .map { #"{"organization":{"uuid":"\#($0)"}}"# }
        .joined(separator: ",")

    return HTTPResponseData(
        data: Data(
            #"{"account":{"memberships":[\#(memberships)]}}"#.utf8
        ),
        response: HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}

private func makeClaudeUsageResponse(
    for request: URLRequest,
    usedPercent: Int
) throws -> HTTPResponseData {
    HTTPResponseData(
        data: Data(
            """
            {
              "limits": [
                {
                  "kind": "session",
                  "group": "session",
                  "percent": \(usedPercent),
                  "resets_at": "2026-07-26T15:10:00.082855+00:00",
                  "is_active": true
                }
              ]
            }
            """.utf8
        ),
        response: HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}

private func makeClaudeCookie(
    name: String,
    value: String
) throws -> HTTPCookie {
    try #require(
        HTTPCookie(
            properties: [
                .name: name,
                .value: value,
                .domain: ".claude.ai",
                .path: "/",
                .secure: "TRUE",
            ]
        )
    )
}

@MainActor
private func makeRefreshTransport(
    usageAccountID: String,
    catalogJSON: String
) -> MockHTTPTransport {
    MockHTTPTransport { request in
        switch request.url?.path {
        case "/api/auth/session":
            return HTTPResponseData(
                data: Data(
                    """
                    {
                      "accessToken": "token-alpha",
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
                              "accessToken": "token-alpha",
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
