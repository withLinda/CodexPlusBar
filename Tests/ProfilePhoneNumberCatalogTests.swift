import Foundation
import Testing
@testable import CodexPlusBar

struct ProfilePhoneNumberCatalogTests {
    @Test
    func savedNumbersAreTrimmedAndDeduplicatedByDigits() {
        let profiles = [
            snapshot("  +63 966 894 3311  ", sortOrder: 0),
            snapshot("+63-966-894-3311", sortOrder: 1),
            snapshot(nil, sortOrder: 2),
            snapshot("  ", sortOrder: 3),
            snapshot("+62 812 345 678", sortOrder: 4),
        ]

        #expect(ProfilePhoneNumberCatalog.savedNumbers(in: profiles) == [
            "+63 966 894 3311",
            "+62 812 345 678",
        ])
    }

    @Test
    func dropdownSearchIgnoresFormattingAndRanksExactThenPrefixThenPartial() {
        let numbers = [
            "+63 966 894 3311",
            "+62 812 345 678",
            "+63 966 000 0000",
            "966 894 3311",
        ]

        #expect(ProfilePhoneNumberCatalog.matches(numbers, query: "9668943311") == [
            "966 894 3311",
            "+63 966 894 3311",
        ])
        #expect(ProfilePhoneNumberCatalog.matches(numbers, query: "+63 966") == [
            "+63 966 894 3311",
            "+63 966 000 0000",
        ])
        #expect(ProfilePhoneNumberCatalog.matches(numbers, query: "345-67") == [
            "+62 812 345 678",
        ])
    }

    @Test
    func numberGroupsMatchFormattingVariantsAndIncludeUniqueNumbers() {
        let first = snapshot("+63 966 894 3311", sortOrder: 0)
        let second = snapshot("+62 812 345 678", sortOrder: 1)
        let third = snapshot("+63-966-894-3311", sortOrder: 2)
        let fourth = snapshot("+63 (966) 894 3311", sortOrder: 3)
        let fifth = snapshot("+62 811 000 000", sortOrder: 4)

        let groups = ProfilePhoneNumberCatalog.numberGroups(
            in: [first, second, third, fourth, fifth]
        )

        #expect(groups.count == 3)
        #expect(groups.first?.phoneNumber == "+63 966 894 3311")
        #expect(groups.first?.profiles.map(\.id) == [first.id, third.id, fourth.id])
        #expect(groups.dropFirst().map(\.phoneNumber) == [
            "+62 812 345 678",
            "+62 811 000 000",
        ])
    }

    @Test
    func numberGroupsPutSharedReuseFirstAndKeepStableOrderForTies() {
        let firstA = snapshot("111 222", sortOrder: 0)
        let secondA = snapshot("111-222", sortOrder: 1)
        let firstB = snapshot("333 444", sortOrder: 2)
        let secondB = snapshot("333-444", sortOrder: 3)
        let thirdB = snapshot("(333) 444", sortOrder: 4)
        let firstC = snapshot("555 666", sortOrder: 5)
        let secondC = snapshot("555-666", sortOrder: 6)
        let unique = snapshot("777 888", sortOrder: 7)

        let groups = ProfilePhoneNumberCatalog.numberGroups(
            in: [firstA, secondA, firstB, secondB, thirdB, firstC, secondC, unique]
        )

        #expect(groups.map(\.phoneNumber) == ["333 444", "111 222", "555 666", "777 888"])
        #expect(groups.map { $0.profiles.count } == [3, 2, 2, 1])
    }

    @Test
    func profilesWithoutNumberIncludeNilAndWhitespaceValues() {
        let saved = snapshot("+62 812 345", sortOrder: 0)
        let missing = snapshot(nil, sortOrder: 1)
        let blank = snapshot("   ", sortOrder: 2)

        let profiles = ProfilePhoneNumberCatalog.profilesWithoutNumber(
            in: [saved, missing, blank]
        )

        #expect(profiles.map(\.id) == [missing.id, blank.id])
    }
}

private func snapshot(_ phoneNumber: String?, sortOrder: Int) -> PlusProfileSnapshot {
    PlusProfileSnapshot(
        profile: PlusProfile(
            id: UUID(),
            label: "profile-\(sortOrder)@example.com",
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
