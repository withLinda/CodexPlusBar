import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileDisplayOrderingTests {
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
    createdAt: Date
) -> PlusProfileSnapshot {
    PlusProfileSnapshot(
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
        usage: nil,
        statusMessage: nil,
        isRefreshing: false
    )
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}
