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
            emailLink: "https://mail.google.com",
            detectedNote: "Plus · acct_b",
            lastKnownState: .needsLogin
        )

        try store.saveProfiles([first, second])

        let loaded = try store.loadProfiles()

        #expect(loaded.map(\.id) == [first.id, second.id])
        #expect(loaded.map(\.webDataStoreID) == [first.webDataStoreID, second.webDataStoreID])
        #expect(loaded.map(\.label) == ["alpha@example.com", "beta@example.com"])
        #expect(loaded.map(\.emailLink) == [nil, "https://mail.google.com"])
        #expect(loaded.map(\.lastKnownState) == [.active, .needsLogin])
    }

    @Test
    func loadProfilesDecodesOlderJSONWithoutEmailLink() throws {
        let tempDirectory = makeTemporaryDirectory()
        let fileURL = tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        let store = ProfileCatalogStore(fileURL: fileURL)
        let legacyJSON = """
        [
          {
            "id" : "4D3DD8D1-7408-4B71-A72D-4ED8CB2616EB",
            "label" : "legacy@example.com",
            "detectedNote" : null,
            "webDataStoreID" : "CC19D410-7A2C-4D41-967A-97FCA178D0F2",
            "sortOrder" : 0,
            "createdAt" : 777600000,
            "lastRefreshAt" : null,
            "lastKnownState" : "unknown"
          }
        ]
        """

        try legacyJSON.data(using: .utf8)?.write(to: fileURL, options: .atomic)

        let loaded = try store.loadProfiles()

        #expect(loaded.count == 1)
        #expect(loaded.first?.label == "legacy@example.com")
        #expect(loaded.first?.emailLink == nil)
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
    emailLink: String? = nil,
    detectedNote: String? = nil,
    lastKnownState: PlusProfileStoredState = .unknown
) -> PlusProfile {
    let createdAt = Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder))

    return PlusProfile(
        id: UUID(),
        label: label,
        emailLink: emailLink,
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
