import Foundation
import Testing
@testable import CodexPlusBar

struct PlusProfileModelsTests {
    @Test
    func profileTagsNormalizeToDisplayOrderWithoutDuplicates() {
        let tags = PlusProfile.normalizedTags([.pending, .active, .needAction, .active])

        #expect(tags == [.active, .needAction, .pending])
        #expect(tags.map(\.rawValue) == ["active", "need_action", "pending"])
        #expect(tags.map(\.displayName) == ["Active", "Need action", "Pending"])
        #expect(PlusProfileTag.active.statusTone == .success)
        #expect(PlusProfileTag.needAction.statusTone == .critical)
        #expect(PlusProfileTag.pending.statusTone == .info)
        #expect(PlusProfileTag.needAction.systemImage == "exclamationmark.triangle")
    }

    @Test
    func profileTagCountsSummarizeStatusBuckets() {
        let active = sampleSnapshot(tags: [.active])
        let action = sampleSnapshot(tags: [.needAction, .pending])
        let pending = sampleSnapshot(tags: [.pending])
        let untagged = sampleSnapshot(tags: [])

        let counts = ProfileTagCounts(snapshots: [active, action, pending, untagged])

        #expect(counts.active == 1)
        #expect(counts.needAction == 1)
        #expect(counts.pending == 2)
        #expect(counts.count(for: .needAction) == 1)
        #expect(counts.statusText == "1 active · 1 need action · 2 pending")
    }

    @Test
    func compactTagSummaryUsesPriorityTagAndOverflowCount() {
        let summary = ProfileTagSummary(tags: [.active, .pending, .needAction])

        #expect(summary.primaryTag == .needAction)
        #expect(summary.overflowCount == 2)
        #expect(summary.accessibilityValue == "Need action, Active, Pending")
    }

    @Test
    func compactTagSummaryCollapsesWhenTagsAreEmpty() {
        let summary = ProfileTagSummary(tags: [])

        #expect(summary.primaryTag == nil)
        #expect(summary.overflowCount == 0)
        #expect(summary.accessibilityValue == "No tags")
    }

    @Test
    func profileDecoderDefaultsMissingTagsToEmpty() throws {
        let json = """
        {
          "id" : "4D3DD8D1-7408-4B71-A72D-4ED8CB2616EB",
          "label" : "legacy@example.com",
          "emailLink" : null,
          "detectedNote" : null,
          "expiresAt" : null,
          "webDataStoreID" : "CC19D410-7A2C-4D41-967A-97FCA178D0F2",
          "sortOrder" : 0,
          "createdAt" : 777600000,
          "lastRefreshAt" : null,
          "lastKnownState" : "unknown"
        }
        """

        let profile = try JSONDecoder().decode(PlusProfile.self, from: try #require(json.data(using: .utf8)))

        #expect(profile.tags == [])
    }

    @Test
    func profileDecoderNormalizesStoredTagsAndSkipsUnknownValues() throws {
        let json = """
        {
          "id" : "4D3DD8D1-7408-4B71-A72D-4ED8CB2616EB",
          "label" : "tagged@example.com",
          "emailLink" : null,
          "detectedNote" : null,
          "expiresAt" : null,
          "webDataStoreID" : "CC19D410-7A2C-4D41-967A-97FCA178D0F2",
          "sortOrder" : 0,
          "createdAt" : 777600000,
          "lastRefreshAt" : null,
          "lastKnownState" : "unknown",
          "tags" : ["pending", "active", "future_tag", "active", "need_action"]
        }
        """

        let profile = try JSONDecoder().decode(PlusProfile.self, from: try #require(json.data(using: .utf8)))

        #expect(profile.tags == [.active, .needAction, .pending])
    }

    @Test
    func resolvedEmailLinkURLReturnsExistingSchemeURL() {
        let profile = sampleProfile(emailLink: "mailto:test@example.com")

        #expect(profile.normalizedEmailLink == "mailto:test@example.com")
        #expect(profile.resolvedEmailLinkURL?.absoluteString == "mailto:test@example.com")
    }

    @Test
    func resolvedEmailLinkURLAddsHTTPSWhenSchemeIsMissing() {
        let profile = sampleProfile(emailLink: "mail.google.com/mail/u/0/#inbox")

        #expect(profile.normalizedEmailLink == "mail.google.com/mail/u/0/#inbox")
        #expect(profile.resolvedEmailLinkURL?.absoluteString == "https://mail.google.com/mail/u/0/#inbox")
    }

    @Test
    func resolvedEmailLinkURLReturnsNilForBlankOrInvalidInput() {
        #expect(sampleProfile(emailLink: "   ").normalizedEmailLink == nil)
        #expect(sampleProfile(emailLink: "   ").resolvedEmailLinkURL == nil)
        #expect(sampleProfile(emailLink: "https:///").resolvedEmailLinkURL == nil)
    }

    @Test
    func usageSummaryIncludesBothWindowsWithFullPercentAndResetText() {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let summary = sampleUsage(referenceDate: referenceDate).usageSummary(referenceDate: referenceDate)

        #expect(summary.primary.shortTitle == "5H")
        #expect(summary.primary.valueText == "78%")
        #expect(summary.primary.resetText == "4h 59m")
        #expect(summary.secondary.shortTitle == "7D")
        #expect(summary.secondary.valueText == "62%")
        #expect(summary.secondary.resetText == "4d 23h")
        #expect(summary.accessibilityValue == "5H 78%, resets in 4h 59m. 7D 62%, resets in 4d 23h.")
    }

    @Test
    func usageSummaryKeepsSevenDayPlaceholderWhenWindowIsUnavailable() {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let usage = PlusProfileUsage(
            accountID: "acct_alpha",
            planType: "chatgpt_plus",
            primaryWindow: WorkspaceLimitWindow(
                usedPercent: 22,
                limitWindowSeconds: 18_000,
                resetAfterSeconds: 17_940,
                resetAt: referenceDate.addingTimeInterval(17_940)
            ),
            secondaryWindow: nil,
            fetchedAt: referenceDate
        )

        let summary = usage.usageSummary(referenceDate: referenceDate)

        #expect(summary.secondary.shortTitle == "7D")
        #expect(summary.secondary.valueText == "—")
        #expect(summary.secondary.resetText == "Unavailable")
        #expect(summary.accessibilityValue == "5H 78%, resets in 4h 59m. 7D unavailable.")
    }
}

private func sampleSnapshot(tags: [PlusProfileTag]) -> PlusProfileSnapshot {
    PlusProfileSnapshot(
        profile: sampleProfile(emailLink: nil, tags: tags),
        state: .idle,
        usage: nil,
        statusMessage: nil,
        isRefreshing: false
    )
}

private func sampleProfile(emailLink: String?, tags: [PlusProfileTag] = []) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: "alpha@example.com",
        emailLink: emailLink,
        detectedNote: nil,
        tags: tags,
        webDataStoreID: UUID(),
        sortOrder: 0,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}

private func sampleUsage(referenceDate: Date) -> PlusProfileUsage {
    PlusProfileUsage(
        accountID: "acct_alpha",
        planType: "chatgpt_plus",
        primaryWindow: WorkspaceLimitWindow(
            usedPercent: 22,
            limitWindowSeconds: 18_000,
            resetAfterSeconds: 17_940,
            resetAt: referenceDate.addingTimeInterval(17_940)
        ),
        secondaryWindow: WorkspaceLimitWindow(
            usedPercent: 38,
            limitWindowSeconds: 604_800,
            resetAfterSeconds: 428_400,
            resetAt: referenceDate.addingTimeInterval(428_400)
        ),
        fetchedAt: referenceDate
    )
}
