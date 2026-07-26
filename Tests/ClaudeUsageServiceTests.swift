import Foundation
import Testing
@testable import CodexPlusBar

struct ClaudeUsageServiceTests {
    @Test
    func requestUsesExpectedOrganizationUsageGETEndpoint() {
        let request = ClaudeUsageService.makeUsageRequest()

        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://claude.ai/api/organizations/"
                    + "37255346-bbc8-48a0-9d5e-a3e3329a3d80/usage"
        )
    }

    @Test
    func limitsSessionEntryBuildsFiveHourWindow() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try ClaudeUsageService.decodeSnapshot(
            from: Data(
                """
                {
                  "five_hour": {
                    "utilization": 81.0,
                    "resets_at": "2026-07-26T18:00:00+00:00"
                  },
                  "seven_day": null,
                  "limits": [
                    {
                      "kind": "session",
                      "group": "session",
                      "percent": 2,
                      "severity": "normal",
                      "resets_at": "2026-07-26T15:10:00.082855+00:00",
                      "scope": null,
                      "is_active": true
                    },
                    {
                      "kind": "weekly",
                      "group": "weekly",
                      "percent": 99,
                      "resets_at": "2026-07-30T15:10:00+00:00",
                      "is_active": false
                    }
                  ]
                }
                """.utf8
            ),
            fetchedAt: fetchedAt
        )

        #expect(snapshot.workspaceID == ClaudeWebURLs.organizationID)
        #expect(snapshot.accountID == ClaudeWebURLs.organizationID)
        #expect(snapshot.planType == "claude")
        #expect(snapshot.primaryWindow.usedPercent == 2)
        #expect(snapshot.primaryWindow.remainingPercent == 98)
        #expect(
            snapshot.primaryWindow.resetAt
                == isoDateWithFraction("2026-07-26T15:10:00.082855+00:00")
        )
        #expect(snapshot.secondaryWindow == nil)
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test
    func activeWeeklyLimitBuildsSevenDayWindow() throws {
        let snapshot = try ClaudeUsageService.decodeSnapshot(
            from: Data(
                """
                {
                  "limits": [
                    {
                      "kind": "session",
                      "group": "session",
                      "percent": 5,
                      "resets_at": "2026-07-26T15:10:00+00:00",
                      "is_active": true
                    },
                    {
                      "kind": "weekly",
                      "group": "seven_day",
                      "percent": 40.4,
                      "resets_at": "2026-07-30T15:10:00+00:00",
                      "is_active": true
                    }
                  ]
                }
                """.utf8
            )
        )

        #expect(snapshot.secondaryWindow?.usedPercent == 40)
        #expect(snapshot.secondaryWindow?.remainingPercent == 60)
    }

    @Test
    func htmlResponseMeansSessionNeedsLogin() {
        #expect(throws: ChatGPTAPIError.unauthorized) {
            _ = try ClaudeUsageService.decodeSnapshot(
                from: Data("<html>Sign in</html>".utf8)
            )
        }
    }
}

private func isoDateWithFraction(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
}
