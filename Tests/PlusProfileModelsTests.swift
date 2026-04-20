import Foundation
import Testing
@testable import CodexPlusBar

struct PlusProfileModelsTests {
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

private func sampleProfile(emailLink: String?) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: "alpha@example.com",
        emailLink: emailLink,
        detectedNote: nil,
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
