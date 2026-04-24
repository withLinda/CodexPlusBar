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
            case "/codex/settings/usage":
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
            profileID: profile.id,
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
                    "/codex/settings/usage",
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
            profileID: profile.id,
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
            profileID: profile.id,
            dataStore: .nonPersistent(),
            transport: transport
        )
        let provider = StubRuntimeProvider(runtimeByProfileID: [profile.id: runtime])
        let service = PlusProfileDataService(runtimeProvider: provider)

        let result = try await service.refreshProfile(profile)

        #expect(result.usage.accountID == "user-not-listed-in-catalog")
        #expect(result.expiryRefresh == .value(isoDate("2026-05-17T13:42:54+00:00")))
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
            profileID: profile.id,
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
        case "/codex/settings/usage":
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

private func sampleProfile(label: String, sortOrder: Int) -> PlusProfile {
    PlusProfile(
        id: UUID(),
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
