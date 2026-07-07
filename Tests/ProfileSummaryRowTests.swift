import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileSummaryRowTests {
    @Test
    func readyMenuBarPresentationUsesExpiryLineInsteadOfDetectedNote() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let snapshot = sampleSnapshot(
            state: .ready,
            usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: 62),
            note: "Plus · Alpha",
            expiresAt: referenceDate.addingTimeInterval(TimeInterval((17 * 24 + 5) * 3_600)),
            statusMessage: nil,
            isRefreshing: false,
            emailLink: "https://mail.google.com"
        )

        let presentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            referenceDate: referenceDate,
            mode: .menuBar(isPinned: false)
        )

        let usageSummary = try #require(presentation.usageSummary)
        #expect(usageSummary.primary.valueText == "78%")
        #expect(usageSummary.secondary.valueText == "62%")
        #expect(presentation.expiryValue == DisplayFormatter.LabeledValue(label: "Expires in", value: "17d 5h"))
        #expect(presentation.expiryEmphasisToken == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(presentation.supportStyle == .muted)
        #expect(presentation.showsStatusBadge == false)
        #expect(presentation.showsInlineSecondaryActions == true)
        #expect(presentation.canOpenEmailLink == true)
        #expect(presentation.showsPinAction == true)
        #expect(presentation.pinActionSymbolName == "pin.circle")
        #expect(presentation.pinActionAccessibilityLabel == "Show on top")
        #expect(presentation.accessory == .none)
    }

    @Test
    func readySidebarPresentationAlsoUsesExpiryLine() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let snapshot = sampleSnapshot(
            state: .ready,
            usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: nil),
            note: "Plus · Beta",
            expiresAt: referenceDate.addingTimeInterval(TimeInterval(5 * 24 * 3_600)),
            statusMessage: nil,
            isRefreshing: false,
            emailLink: nil
        )

        let presentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            referenceDate: referenceDate,
            mode: .sidebar(isSelected: false)
        )

        let usageSummary = try #require(presentation.usageSummary)
        #expect(usageSummary.secondary.valueText == "—")
        #expect(usageSummary.secondary.resetText == "Unavailable")
        #expect(presentation.supportText == "Plus · Beta")
        #expect(presentation.expiryValue == DisplayFormatter.LabeledValue(label: "Expires in", value: "5d"))
        #expect(presentation.expiryEmphasisToken == CodexTheme.readableAccentToken(CodexTheme.Palette.accOrange))
        #expect(presentation.supportStyle == .muted)
    }

    @Test
    func needsLoginPresentationUsesSupportLineInsteadOfStatusBadge() {
        let snapshot = sampleSnapshot(
            state: .needsLogin,
            usage: nil,
            note: "Plus · Gamma",
            expiresAt: nil,
            statusMessage: "Sign in again to restore this account.",
            isRefreshing: false,
            emailLink: nil
        )

        let presentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            mode: .menuBar(isPinned: false)
        )

        #expect(presentation.usageSummary == nil)
        #expect(presentation.supportText == "Sign in again to restore this account.")
        #expect(presentation.supportStyle == .emphasized(.warning))
        #expect(presentation.showsStatusBadge == false)
    }

    @Test
    func failedPresentationUsesErrorSupportLineInsteadOfStatusBadge() {
        let snapshot = sampleSnapshot(
            state: .failed,
            usage: nil,
            note: "Plus · Delta",
            expiresAt: nil,
            statusMessage: "Refresh this profile in the manager window.",
            isRefreshing: false,
            emailLink: nil
        )

        let presentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            mode: .sidebar(isSelected: false)
        )

        #expect(presentation.usageSummary == nil)
        #expect(presentation.supportText == "Refresh this profile in the manager window.")
        #expect(presentation.supportStyle == .emphasized(.critical))
        #expect(presentation.showsStatusBadge == false)
    }

    @Test
    func pinnedMenuBarPresentationShowsPinnedIconState() {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let snapshot = sampleSnapshot(
            state: .ready,
            usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: 62),
            note: "Plus · Epsilon",
            expiresAt: referenceDate.addingTimeInterval(TimeInterval(2 * 24 * 3_600)),
            statusMessage: nil,
            isRefreshing: false,
            emailLink: nil
        )

        let presentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            referenceDate: referenceDate,
            mode: .menuBar(isPinned: true)
        )

        #expect(presentation.accessory == .none)
        #expect(presentation.showsInlineSecondaryActions == true)
        #expect(presentation.canOpenEmailLink == false)
        #expect(presentation.showsPinAction == true)
        #expect(presentation.pinActionSymbolName == "pin.circle.fill")
        #expect(presentation.pinActionAccessibilityLabel == "On top")
        #expect(presentation.expiryValue == DisplayFormatter.LabeledValue(label: "Expires in", value: "2d"))
        #expect(presentation.expiryEmphasisToken == CodexTheme.readableAccentToken(CodexTheme.Palette.accRed))
    }

    @Test
    func rowPresentationExposesTagsOnlyWhenPresent() {
        let tagged = sampleSnapshot(
            state: .needsLogin,
            usage: nil,
            note: nil,
            expiresAt: nil,
            statusMessage: nil,
            isRefreshing: false,
            emailLink: nil,
            tags: [.pending, .active]
        )
        let untagged = sampleSnapshot(
            state: .ready,
            usage: nil,
            note: nil,
            expiresAt: nil,
            statusMessage: nil,
            isRefreshing: false,
            emailLink: nil,
            tags: []
        )

        let taggedPresentation = ProfileSummaryRowPresentation(
            snapshot: tagged,
            mode: .sidebar(isSelected: false)
        )
        let untaggedPresentation = ProfileSummaryRowPresentation(
            snapshot: untagged,
            mode: .menuBar(isPinned: false)
        )

        #expect(taggedPresentation.tags == [.active, .pending])
        #expect(taggedPresentation.showsTags)
        #expect(taggedPresentation.compactTagSummary.primaryTag == .pending)
        #expect(taggedPresentation.compactTagSummary.overflowCount == 1)
        #expect(untaggedPresentation.tags == [])
        #expect(untaggedPresentation.showsTags == false)
        #expect(untaggedPresentation.compactTagSummary.primaryTag == nil)
    }

    @Test
    func rowPresentationMasksEmailTitleInSidebarAndMenuBar() {
        let snapshot = sampleSnapshot(
            state: .ready,
            usage: nil,
            note: nil,
            expiresAt: nil,
            statusMessage: nil,
            isRefreshing: false,
            emailLink: nil,
            label: "alphaexample@example.com"
        )

        let sidebarPresentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            mode: .sidebar(isSelected: false)
        )
        let menuPresentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            mode: .menuBar(isPinned: false)
        )

        #expect(sidebarPresentation.title == "alphae**mple@example.com")
        #expect(menuPresentation.title == "alphae**mple@example.com")
    }
}

private func sampleSnapshot(
    state: PlusProfileState,
    usage: PlusProfileUsage?,
    note: String?,
    expiresAt: Date?,
    statusMessage: String?,
    isRefreshing: Bool,
    emailLink: String?,
    tags: [PlusProfileTag] = [],
    label: String = "alpha@example.com"
) -> PlusProfileSnapshot {
    PlusProfileSnapshot(
        profile: PlusProfile(
            id: UUID(),
            label: label,
            emailLink: emailLink,
            detectedNote: note,
            expiresAt: expiresAt,
            tags: tags,
            webDataStoreID: UUID(),
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_776_000_000),
            lastRefreshAt: nil,
            lastKnownState: state.storedState
        ),
        state: state,
        usage: usage,
        statusMessage: statusMessage,
        isRefreshing: isRefreshing
    )
}

private func sampleUsage(
    referenceDate: Date,
    sevenDayRemainingPercent: Int?
) -> PlusProfileUsage {
    PlusProfileUsage(
        accountID: "acct_alpha",
        planType: "chatgpt_plus",
        primaryWindow: WorkspaceLimitWindow(
            usedPercent: 22,
            limitWindowSeconds: 18_000,
            resetAfterSeconds: 17_940,
            resetAt: referenceDate.addingTimeInterval(17_940)
        ),
        secondaryWindow: sevenDayRemainingPercent.map {
            WorkspaceLimitWindow(
                usedPercent: 100 - $0,
                limitWindowSeconds: 604_800,
                resetAfterSeconds: 428_400,
                resetAt: referenceDate.addingTimeInterval(428_400)
            )
        },
        fetchedAt: referenceDate
    )
}
