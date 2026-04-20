import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct PlusProfileDataServiceTests {
    @Test
    func refreshProfileFetchesSessionThenUsageAndBuildsDetectedNote() async throws {
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
        #expect(transport.requestPaths == ["/api/auth/session", "/codex/settings/usage", "/backend-api/wham/usage"])
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

private func sampleProfile(label: String, sortOrder: Int) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: label,
        detectedNote: nil,
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}
