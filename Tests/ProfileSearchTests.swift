import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileSearchTests {
    @Test
    func emptyQueryKeepsTheExistingDisplayOrder() {
        let profiles = [
            snapshot("later@example.com", sortOrder: 1),
            snapshot("first@example.com", sortOrder: 0),
        ]

        #expect(ProfileSearch.filter(profiles, query: "   ").map(\.label) == [
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

        #expect(ProfileSearch.filter(profiles, query: "ALPHA@EXAMPLE.COM").map(\.label) == [
            "alpha@example.com",
        ])
        #expect(ProfileSearch.filter(profiles, query: "  alpha @ example.com  ").map(\.label) == [
            "alpha@example.com",
        ])
        #expect(ProfileSearch.filter(profiles, query: "sample").map(\.label) == [
            "beta@sample.org",
        ])
        #expect(ProfileSearch.filter(profiles, query: "pha@exa").map(\.label) == [
            "alpha@example.com",
        ])
    }

    @Test
    func pastedMailtoEmailIsNormalized() {
        let profiles = [snapshot("person@example.com", sortOrder: 0)]

        #expect(ProfileSearch.normalizedQuery(" MAILTO:Person@Example.com ") == "person@example.com")
        #expect(ProfileSearch.filter(profiles, query: "mailto:person@example.com").map(\.label) == [
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

        #expect(ProfileSearch.filter(profiles, query: "alpha@example.com").map(\.label) == [
            "alpha@example.com",
            "team-alpha@example.com",
        ])
        #expect(ProfileSearch.filter(profiles, query: "alpha").map(\.label) == [
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

        #expect(ProfileSearch.filter(profiles, query: "linda@example.com").map(\.label) == [
            "Work account <linda@example.com>",
        ])
        #expect(ProfileSearch.filter(profiles, query: "saved").isEmpty)
    }

    @Test
    func phoneSearchIgnoresFormattingAndAcceptsPartialDigits() {
        let profiles = [
            snapshot("alpha@example.com", phoneNumber: "+63 966 894 3311", sortOrder: 0),
            snapshot("beta@example.com", phoneNumber: "+62 (812) 345-678", sortOrder: 1),
        ]

        #expect(ProfileSearch.filter(profiles, query: "+63 966").map(\.label) == [
            "alpha@example.com",
        ])
        #expect(ProfileSearch.filter(profiles, query: "894-33").map(\.label) == [
            "alpha@example.com",
        ])
        #expect(ProfileSearch.filter(profiles, query: "123456").map(\.label) == [
            "beta@example.com",
        ])
        #expect(ProfileSearch.matchingPhoneNumber(in: profiles[0], query: "966894") == "+63 966 894 3311")
    }

    @Test
    func phoneMatchesRankBeforeNumericEmailMatchesForPhoneLikeQueries() {
        let profiles = [
            snapshot("account3311@example.com", sortOrder: 0),
            snapshot("phone-owner@example.com", phoneNumber: "+63 966 894 3311", sortOrder: 1),
        ]

        #expect(ProfileSearch.filter(profiles, query: "3311").map(\.label) == [
            "phone-owner@example.com",
            "account3311@example.com",
        ])
    }

    @Test
    func digitsInsideAnEmailQueryDoNotTurnIntoAPhoneQuery() {
        let profiles = [
            snapshot("user123@example.com", sortOrder: 0),
            snapshot("other@example.com", phoneNumber: "+62 812 300 000", sortOrder: 1),
        ]

        #expect(ProfileSearch.filter(profiles, query: "user123@example.com").map(\.label) == [
            "user123@example.com",
        ])
    }
}

private func snapshot(
    _ label: String,
    phoneNumber: String? = nil,
    sortOrder: Int
) -> PlusProfileSnapshot {
    PlusProfileSnapshot(
        profile: PlusProfile(
            id: UUID(),
            label: label,
            emailLink: nil,
            detectedNote: nil,
            phoneNumber: phoneNumber,
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
