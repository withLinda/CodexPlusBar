import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileEmailSearchTests {
    @Test
    func emptyQueryKeepsTheExistingDisplayOrder() {
        let profiles = [
            snapshot("later@example.com", sortOrder: 1),
            snapshot("first@example.com", sortOrder: 0),
        ]

        #expect(ProfileEmailSearch.filter(profiles, query: "   ").map(\.label) == [
            "later@example.com",
            "first@example.com",
        ])
    }

    @Test
    func searchAcceptsFullAndPartialEmailWithoutCaseOrSpacingFriction() {
        let profiles = [
            snapshot("alpha@example.com", sortOrder: 0),
            snapshot("beta@sample.org", sortOrder: 1),
        ]

        #expect(ProfileEmailSearch.filter(profiles, query: "ALPHA@EXAMPLE.COM").map(\.label) == [
            "alpha@example.com",
        ])
        #expect(ProfileEmailSearch.filter(profiles, query: "  alpha @ example.com  ").map(\.label) == [
            "alpha@example.com",
        ])
        #expect(ProfileEmailSearch.filter(profiles, query: "sample").map(\.label) == [
            "beta@sample.org",
        ])
        #expect(ProfileEmailSearch.filter(profiles, query: "pha@exa").map(\.label) == [
            "alpha@example.com",
        ])
    }

    @Test
    func pastedMailtoEmailIsNormalized() {
        let profiles = [snapshot("person@example.com", sortOrder: 0)]

        #expect(ProfileEmailSearch.normalizedQuery(" MAILTO:Person@Example.com ") == "person@example.com")
        #expect(ProfileEmailSearch.filter(profiles, query: "mailto:person@example.com").map(\.label) == [
            "person@example.com",
        ])
    }

    @Test
    func rankingPlacesExactThenPrefixThenOtherPartialMatches() {
        let profiles = [
            snapshot("team-alpha@example.com", sortOrder: 0),
            snapshot("alpha@example.com", sortOrder: 1),
            snapshot("alphabet@example.net", sortOrder: 2),
        ]

        #expect(ProfileEmailSearch.filter(profiles, query: "alpha@example.com").map(\.label) == [
            "alpha@example.com",
            "team-alpha@example.com",
        ])
        #expect(ProfileEmailSearch.filter(profiles, query: "alpha").map(\.label) == [
            "alpha@example.com",
            "alphabet@example.net",
            "team-alpha@example.com",
        ])
    }

    @Test
    func decoratedLabelsStillExposeTheirEmailAddressToSearch() {
        let profiles = [
            snapshot("Work account <linda@example.com>", sortOrder: 0),
            snapshot("No saved email", sortOrder: 1),
        ]

        #expect(ProfileEmailSearch.filter(profiles, query: "linda@example.com").map(\.label) == [
            "Work account <linda@example.com>",
        ])
        #expect(ProfileEmailSearch.filter(profiles, query: "saved").isEmpty)
    }
}

private func snapshot(_ label: String, sortOrder: Int) -> PlusProfileSnapshot {
    PlusProfileSnapshot(
        profile: PlusProfile(
            id: UUID(),
            label: label,
            emailLink: nil,
            detectedNote: nil,
            webDataStoreID: UUID(),
            sortOrder: sortOrder,
            createdAt: Date(timeIntervalSince1970: Double(sortOrder)),
            lastRefreshAt: nil,
            lastKnownState: .unknown
        ),
        state: .idle,
        usage: nil,
        statusMessage: nil,
        isRefreshing: false
    )
}
