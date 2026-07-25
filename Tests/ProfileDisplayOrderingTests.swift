import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileDisplayOrderingTests {
    @Test
    func nextResetOrderingUsesEarliestKnownWindowAndPutsUnknownLast() {
        let referenceDate = date("2026-06-01T00:00:00Z")
        let secondaryResetsFirst = makeSnapshot(
            label: "secondary-first@example.com",
            expiresAt: nil,
            sortOrder: 2,
            createdAt: referenceDate,
            primaryResetAt: referenceDate.addingTimeInterval(14_400),
            secondaryResetAt: referenceDate.addingTimeInterval(3_600)
        )
        let primaryResetsSecond = makeSnapshot(
            label: "primary-second@example.com",
            expiresAt: nil,
            sortOrder: 1,
            createdAt: referenceDate,
            primaryResetAt: referenceDate.addingTimeInterval(7_200)
        )
        let unknownReset = makeSnapshot(
            label: "unknown@example.com",
            expiresAt: nil,
            sortOrder: 0,
            createdAt: referenceDate
        )

        let ordered = ProfileDisplayOrder.nextReset.apply(
            to: [unknownReset, primaryResetsSecond, secondaryResetsFirst]
        )

        #expect(secondaryResetsFirst.nextResetAt == referenceDate.addingTimeInterval(3_600))
        #expect(ordered.map(\.label) == [
            "secondary-first@example.com",
            "primary-second@example.com",
            "unknown@example.com",
        ])
    }

    @Test
    func nextResetOrderingUsesSavedOrderForMatchingAndUnknownDates() {
        let resetAt = date("2026-06-01T04:00:00Z")
        let firstKnown = makeSnapshot(
            label: "first-known@example.com",
            expiresAt: nil,
            sortOrder: 0,
            createdAt: date("2026-06-01T00:00:00Z"),
            primaryResetAt: resetAt
        )
        let secondKnown = makeSnapshot(
            label: "second-known@example.com",
            expiresAt: nil,
            sortOrder: 1,
            createdAt: date("2026-06-01T00:00:00Z"),
            primaryResetAt: resetAt
        )
        let firstUnknown = makeSnapshot(
            label: "first-unknown@example.com",
            expiresAt: nil,
            sortOrder: 2,
            createdAt: date("2026-06-01T00:00:00Z")
        )
        let secondUnknown = makeSnapshot(
            label: "second-unknown@example.com",
            expiresAt: nil,
            sortOrder: 3,
            createdAt: date("2026-06-01T00:00:00Z")
        )

        let ordered = ProfileDisplayOrder.nextReset.apply(
            to: [secondUnknown, secondKnown, firstUnknown, firstKnown]
        )

        #expect(ordered.map(\.label) == [
            "first-known@example.com",
            "second-known@example.com",
            "first-unknown@example.com",
            "second-unknown@example.com",
        ])
    }

    @Test
    func expiryFirstOrderingPutsSoonestKnownExpiryFirstAndUnknownLast() {
        let oldestKnown = makeSnapshot(
            label: "oldest@example.com",
            expiresAt: date("2026-06-10T00:00:00Z"),
            sortOrder: 2,
            createdAt: date("2026-06-01T00:00:00Z")
        )
        let soonestKnown = makeSnapshot(
            label: "soonest@example.com",
            expiresAt: date("2026-06-08T00:00:00Z"),
            sortOrder: 1,
            createdAt: date("2026-06-02T00:00:00Z")
        )
        let unknownExpiry = makeSnapshot(
            label: "unknown@example.com",
            expiresAt: nil,
            sortOrder: 0,
            createdAt: date("2026-06-03T00:00:00Z")
        )

        let ordered = PlusProfileSnapshot.expiryFirstDisplayOrder([oldestKnown, unknownExpiry, soonestKnown])

        #expect(ordered.map(\.label) == [
            "soonest@example.com",
            "oldest@example.com",
            "unknown@example.com",
        ])
    }

    @Test
    func expiryFirstOrderingUsesSavedSortOrderWhenExpiryMatches() {
        let first = makeSnapshot(
            label: "first@example.com",
            expiresAt: date("2026-06-08T00:00:00Z"),
            sortOrder: 0,
            createdAt: date("2026-06-03T00:00:00Z")
        )
        let second = makeSnapshot(
            label: "second@example.com",
            expiresAt: date("2026-06-08T00:00:00Z"),
            sortOrder: 1,
            createdAt: date("2026-06-01T00:00:00Z")
        )

        let ordered = PlusProfileSnapshot.expiryFirstDisplayOrder([second, first])

        #expect(ordered.map(\.label) == [
            "first@example.com",
            "second@example.com",
        ])
    }

    @Test
    func expiryFirstOrderingFallsBackToOlderCreationDateWhenExpiryAndSortOrderMatch() {
        let older = makeSnapshot(
            label: "older@example.com",
            expiresAt: date("2026-06-08T00:00:00Z"),
            sortOrder: 0,
            createdAt: date("2026-06-01T00:00:00Z")
        )
        let newer = makeSnapshot(
            label: "newer@example.com",
            expiresAt: date("2026-06-08T00:00:00Z"),
            sortOrder: 0,
            createdAt: date("2026-06-02T00:00:00Z")
        )

        let ordered = PlusProfileSnapshot.expiryFirstDisplayOrder([newer, older])

        #expect(ordered.map(\.label) == [
            "older@example.com",
            "newer@example.com",
        ])
    }
}

private func makeSnapshot(
    label: String,
    expiresAt: Date?,
    sortOrder: Int,
    createdAt: Date,
    primaryResetAt: Date? = nil,
    secondaryResetAt: Date? = nil
) -> PlusProfileSnapshot {
    let usage = primaryResetAt.map { primaryResetAt in
        PlusProfileUsage(
            accountID: "account-\(sortOrder)",
            planType: "chatgpt_plus",
            primaryWindow: WorkspaceLimitWindow(
                usedPercent: 50,
                resetAt: primaryResetAt
            ),
            secondaryWindow: secondaryResetAt.map {
                WorkspaceLimitWindow(usedPercent: 50, resetAt: $0)
            },
            fetchedAt: createdAt
        )
    }

    return PlusProfileSnapshot(
        profile: PlusProfile(
            id: UUID(),
            label: label,
            emailLink: nil,
            detectedNote: nil,
            expiresAt: expiresAt,
            tags: [],
            webDataStoreID: UUID(),
            sortOrder: sortOrder,
            createdAt: createdAt,
            lastRefreshAt: nil,
            lastKnownState: .active
        ),
        state: .ready,
        usage: usage,
        statusMessage: nil,
        isRefreshing: false
    )
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}
