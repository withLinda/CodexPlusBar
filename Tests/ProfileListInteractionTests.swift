import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileListInteractionTests {
    @Test
    func menuSelectionsComposeAndClearTheVisibleListFilter() {
        var filter = ProfileFilter()
        for selection: ProfileFilterSegmentKind in [.tag(.active), .provider(.codex), .limit(.usable)] {
            selection.apply(to: &filter)
        }
        #expect(filter == ProfileFilter([.active], limit: .usable, provider: .codex))
        ProfileFilterSegmentKind.tag(.active).apply(to: &filter)
        #expect(filter == ProfileFilter(limit: .usable, provider: .codex))
        ProfileFilterSegmentKind.all.apply(to: &filter)
        #expect(filter.isEmpty)
    }

    @Test
    func searchRenumbersResultsAndNavigationSkipsHiddenProfiles() {
        let first = interactionTestSnapshot(label: "keep-first@example.com", sortOrder: 0)
        let hidden = interactionTestSnapshot(label: "hidden@example.com", sortOrder: 1)
        let last = interactionTestSnapshot(label: "keep-last@example.com", sortOrder: 2)
        let visible = ProfileListPresentation(profiles: [first, hidden, last], filter: ProfileFilter(), query: "keep", displayOrder: .saved)
        #expect(visible.numberedProfiles.map(\.ordinal) == [1, 2])
        // Search ranks the shorter prefix match ahead of saved order.
        #expect(visible.numberedProfiles.map(\.id) == [last.id, first.id])
        #expect(visible.navigationTarget(from: last.id, direction: .down) == first.id)
        #expect(visible.navigationTarget(from: hidden.id, direction: .up) == last.id)
        let noMatches = ProfileListPresentation(profiles: [first], filter: ProfileFilter(), query: "absent")
        #expect(noMatches.navigationTarget(from: first.id, direction: .down) == nil)
    }

    @Test
    func numberedProfilesFollowTheVisibleSortOrder() {
        let first = interactionTestSnapshot(
            label: "later@example.com",
            sortOrder: 0,
            resetAt: Date(timeIntervalSince1970: 1_776_028_800)
        )
        let second = interactionTestSnapshot(
            label: "soonest@example.com",
            sortOrder: 1,
            resetAt: Date(timeIntervalSince1970: 1_776_007_200)
        )
        let presentation = ProfileListPresentation(
            profiles: [first, second],
            filter: ProfileFilter(),
            query: "",
            displayOrder: .nextFiveHourReset
        )

        #expect(presentation.numberedProfiles.map(\.ordinal) == [1, 2])
        #expect(presentation.numberedProfiles.map(\.snapshot.label) == [
            "soonest@example.com",
            "later@example.com",
        ])

        let savedOrderPresentation = ProfileListPresentation(
            profiles: [first, second],
            filter: ProfileFilter(),
            query: "",
            displayOrder: .saved
        )
        #expect(savedOrderPresentation.numberedProfiles.map(\.snapshot.label) == [
            "later@example.com",
            "soonest@example.com",
        ])
    }

    @Test
    func arrowNavigationUsesVisibleItemsAndStopsAtTheEnds() {
        let first = interactionTestSnapshot(label: "first@example.com", sortOrder: 0)
        let second = interactionTestSnapshot(label: "second@example.com", sortOrder: 1)
        let third = interactionTestSnapshot(label: "third@example.com", sortOrder: 2)
        let presentation = ProfileListPresentation(
            profiles: [first, second, third],
            filter: ProfileFilter(),
            query: "",
            displayOrder: .saved
        )

        #expect(presentation.navigationTarget(from: second.id, direction: .up) == first.id)
        #expect(presentation.navigationTarget(from: second.id, direction: .down) == third.id)
        #expect(presentation.navigationTarget(from: first.id, direction: .up) == first.id)
        #expect(presentation.navigationTarget(from: third.id, direction: .down) == third.id)
        #expect(presentation.navigationTarget(from: UUID(), direction: .down) == first.id)
        #expect(presentation.navigationTarget(from: nil, direction: .up) == first.id)
    }
}

private func interactionTestSnapshot(
    label: String,
    sortOrder: Int,
    resetAt: Date = Date(timeIntervalSince1970: 1_776_018_000)
) -> PlusProfileSnapshot {
    let profile = PlusProfile(
        id: UUID(),
        label: label,
        emailLink: nil,
        detectedNote: "Plus",
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
        lastRefreshAt: nil,
        lastKnownState: .active
    )
    let usage = PlusProfileUsage(
        accountID: "account-\(sortOrder)",
        planType: "chatgpt_plus",
        primaryWindow: WorkspaceLimitWindow(usedPercent: 50, resetAt: resetAt),
        secondaryWindow: nil,
        fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
    )

    return PlusProfileSnapshot(
        profile: profile,
        state: .ready,
        usage: usage,
        statusMessage: nil,
        isRefreshing: false
    )
}
