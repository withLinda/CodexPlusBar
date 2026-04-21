import Foundation
import Testing
@testable import CodexPlusBar

struct AccountCatalogServiceTests {
    @Test
    func makeRequestUsesBrowserTimezoneOffsetSignConvention() {
        let date = Date(timeIntervalSince1970: 1_776_000_000)
        let request = AccountCatalogService.makeRequest(
            now: date,
            timeZone: TimeZone(identifier: "Asia/Jakarta")!
        )
        let components = URLComponents(url: try! #require(request.url), resolvingAgainstBaseURL: false)

        #expect(
            components?.queryItems?.first(where: { $0.name == "timezone_offset_min" })?.value == "-420"
        )
    }

    @Test
    func decodeCatalogReadsEntitlementExpiryFromAccountsPayload() throws {
        let data = Data(
            """
            {
              "account_ordering": ["acct_beta", "acct_alpha"],
              "accounts": {
                "acct_alpha": {
                  "account": {
                    "id": "acct_alpha",
                    "name": "Alpha",
                    "plan_type": "chatgpt_plus"
                  },
                  "entitlement": {
                    "expires_at": "2026-05-01T10:00:00+00:00",
                    "has_active_subscription": true
                  }
                },
                "acct_beta": {
                  "account": {
                    "id": "acct_beta",
                    "name": "Beta",
                    "plan_type": "chatgpt_plus"
                  },
                  "entitlement": {
                    "expires_at": "2026-04-25T08:30:00+00:00",
                    "has_active_subscription": true
                  }
                }
              }
            }
            """.utf8
        )

        let catalog = try AccountCatalogService.decodeCatalog(from: data)

        #expect(catalog.map(\.accountID) == ["acct_beta", "acct_alpha"])
        #expect(catalog.first?.expiresAt == date("2026-04-25T08:30:00+00:00"))
        #expect(catalog.last?.expiresAt == date("2026-05-01T10:00:00+00:00"))
    }
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}
