import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileCatalogStoreTests {
    @Test
    func saveAndLoadProfilesPreservesOrderAndIdentifiers() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "alpha@example.com", sortOrder: 0, lastKnownState: .active)
        let second = sampleProfile(
            label: "beta@example.com",
            sortOrder: 1,
            detectedNote: "Plus · acct_b",
            lastKnownState: .needsLogin
        )

        try store.saveProfiles([first, second])

        let loaded = try store.loadProfiles()

        #expect(loaded.map(\.id) == [first.id, second.id])
        #expect(loaded.map(\.webDataStoreID) == [first.webDataStoreID, second.webDataStoreID])
        #expect(loaded.map(\.label) == ["alpha@example.com", "beta@example.com"])
        #expect(loaded.map(\.lastKnownState) == [.active, .needsLogin])
    }

    @Test
    func upsertProfileReplacesExistingEntryWithoutTouchingOtherProfiles() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let second = sampleProfile(label: "beta@example.com", sortOrder: 1)
        try store.saveProfiles([first, second])

        var updatedFirst = first
        updatedFirst.label = "alpha+renamed@example.com"
        updatedFirst.detectedNote = "Plus · acct_new"
        updatedFirst.lastKnownState = .active

        try store.upsertProfile(updatedFirst)

        let loaded = try store.loadProfiles()

        #expect(loaded.count == 2)
        #expect(loaded.first?.label == "alpha+renamed@example.com")
        #expect(loaded.first?.detectedNote == "Plus · acct_new")
        #expect(loaded.last?.id == second.id)
        #expect(loaded.last?.label == "beta@example.com")
    }

    @Test
    func removeProfileDeletesOnlyRequestedEntry() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let second = sampleProfile(label: "beta@example.com", sortOrder: 1)
        try store.saveProfiles([first, second])

        try store.removeProfile(id: first.id)

        let loaded = try store.loadProfiles()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == second.id)
        #expect(loaded.first?.label == "beta@example.com")
    }
}

private func sampleProfile(
    label: String,
    sortOrder: Int,
    detectedNote: String? = nil,
    lastKnownState: PlusProfileStoredState = .unknown
) -> PlusProfile {
    let createdAt = Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder))

    return PlusProfile(
        id: UUID(),
        label: label,
        detectedNote: detectedNote,
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: createdAt,
        lastRefreshAt: nil,
        lastKnownState: lastKnownState
    )
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
