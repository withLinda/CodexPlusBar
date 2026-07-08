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
        #expect(PlusProfileTag.active.profileTagTone == .active)
        #expect(PlusProfileTag.needAction.profileTagTone == .needAction)
        #expect(PlusProfileTag.pending.profileTagTone == .pending)
        #expect(PlusProfileTag.needAction.systemImage == "exclamationmark.triangle")
        #expect(PlusProfileTag.active.systemImage != PlusProfileTag.pending.systemImage)
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
        #expect(profile.password == nil)
        #expect(profile.twoFactorCode == nil)
        #expect(profile.phoneNumber == nil)
        #expect(profile.notes == nil)
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
    func bulkProfileImportParsesPipeSeparatedRowsAndSkipsBlankLines() throws {
        let preview = BulkProfileImporter.preview(
            from: """

            denture-soggier.7q+28mxc@icloud.com|KSEt7!LpF7&c|Y2GWFRZO6MYAX7M6DMVVUNTKDF47T5YP

            62-turtle-hibachi+dzfobh@icloud.com | 8jub31^kHeuB | XHIONYU4LL74C2F5PBHR6YD5DF7ZF3BD
            swipes.risings-9o+fa7yn@icloud.com|5^VAP%%WnjaO|4H6EJROBQMAE6TIKBL3IUW4ZKIGR2QIZ
            """
        )

        #expect(preview.issues == [])
        #expect(preview.canSubmit)
        #expect(preview.countText == "3 profiles ready")
        #expect(preview.entries.map(\.email) == [
            "denture-soggier.7q+28mxc@icloud.com",
            "62-turtle-hibachi+dzfobh@icloud.com",
            "swipes.risings-9o+fa7yn@icloud.com",
        ])
        let second = try #require(preview.entries.dropFirst().first)
        #expect(second.password == "8jub31^kHeuB")
        #expect(second.twoFactorCode == "XHIONYU4LL74C2F5PBHR6YD5DF7ZF3BD")
    }

    @Test
    func bulkProfileImportReportsLineIssuesBeforeImport() {
        let preview = BulkProfileImporter.preview(
            from: """
            valid@example.com|password|JBSWY3DPEHPK3PXP
            missing-pipes@example.com password JBSWY3DPEHPK3PXP
            |blank-email|JBSWY3DPEHPK3PXP
            empty-code@example.com|password|
            """
        )

        #expect(preview.entries.map(\.email) == ["valid@example.com"])
        #expect(preview.canSubmit == false)
        #expect(preview.countText == "1 profile ready")
        #expect(preview.issues.map(\.lineNumber) == [2, 3, 4])
        #expect(preview.issues.map(\.message) == [
            "Use email|password|2FA",
            "Email is empty",
            "2FA code is empty",
        ])
        #expect(preview.issueSummary == "Fix lines 2, 3, 4")
    }

    @Test
    func detailsDraftPreservesPrivateTextAndNormalizesOptionalValues() {
        let updated = PlusProfileDetailsDraft(
            label: "owner@example.com",
            emailLink: "  mail.example.com  ",
            password: " pass with spaces ",
            twoFactorCode: " JBSW Y3DP ",
            phoneNumber: "  +62 812 3456  ",
            notes: "  Temporary account  "
        ).applying(to: sampleProfile(emailLink: nil))

        #expect(updated.label == "owner@example.com")
        #expect(updated.emailLink == "mail.example.com")
        #expect(updated.password == " pass with spaces ")
        #expect(updated.twoFactorCode == " JBSW Y3DP ")
        #expect(updated.phoneNumber == "+62 812 3456")
        #expect(updated.notes == "Temporary account")
    }

    @Test
    func detailsDraftNormalizesWhitespaceOnlyOptionalValuesToNil() {
        let updated = PlusProfileDetailsDraft(
            label: "owner@example.com",
            emailLink: " ",
            password: "\n",
            twoFactorCode: "\t",
            phoneNumber: "  ",
            notes: "\n "
        ).applying(to: sampleProfile(emailLink: "https://mail.example.com"))

        #expect(updated.emailLink == nil)
        #expect(updated.password == nil)
        #expect(updated.twoFactorCode == nil)
        #expect(updated.phoneNumber == nil)
        #expect(updated.notes == nil)
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
