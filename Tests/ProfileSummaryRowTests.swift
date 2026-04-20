import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileSummaryRowTests {
    @Test
    func readyPresentationUsesUsageSummaryAndMutedSupportLine() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let snapshot = sampleSnapshot(
            state: .ready,
            usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: 62),
            note: "Plus · Alpha",
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
        #expect(presentation.supportText == "Plus · Alpha")
        #expect(presentation.supportStyle == .muted)
        #expect(presentation.showsStatusBadge == false)
        #expect(presentation.showsInlineSecondaryActions == true)
        #expect(presentation.canOpenEmailLink == true)
        #expect(presentation.showsPinnedCapsule == true)
        #expect(presentation.pinnedCapsuleTitle == "Show on top")
        #expect(presentation.accessory == .none)
    }

    @Test
    func readyPresentationKeepsUnavailableSevenDayWindow() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let snapshot = sampleSnapshot(
            state: .ready,
            usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: nil),
            note: "Plus · Beta",
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
        #expect(presentation.supportStyle == .muted)
    }

    @Test
    func needsLoginPresentationUsesSupportLineInsteadOfStatusBadge() {
        let snapshot = sampleSnapshot(
            state: .needsLogin,
            usage: nil,
            note: "Plus · Gamma",
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
    func pinnedMenuBarPresentationShowsPinnedCapsuleState() {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let snapshot = sampleSnapshot(
            state: .ready,
            usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: 62),
            note: "Plus · Epsilon",
            statusMessage: nil,
            isRefreshing: false,
            emailLink: nil
        )

        let presentation = ProfileSummaryRowPresentation(
            snapshot: snapshot,
            referenceDate: referenceDate,
            mode: .menuBar(isPinned: true)
        )

        #expect(presentation.accessory == .pinned)
        #expect(presentation.showsInlineSecondaryActions == true)
        #expect(presentation.canOpenEmailLink == false)
        #expect(presentation.showsPinnedCapsule == true)
        #expect(presentation.pinnedCapsuleTitle == "On top")
    }
}

private func sampleSnapshot(
    state: PlusProfileState,
    usage: PlusProfileUsage?,
    note: String?,
    statusMessage: String?,
    isRefreshing: Bool,
    emailLink: String?
) -> PlusProfileSnapshot {
    PlusProfileSnapshot(
        profile: PlusProfile(
            id: UUID(),
            label: "alpha@example.com",
            emailLink: emailLink,
            detectedNote: note,
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
