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
