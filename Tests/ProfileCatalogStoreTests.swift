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
            expiresAt: Date(timeIntervalSince1970: 1_779_097_600),
            tags: [.pending, .active],
            lastKnownState: .needsLogin
        )

        try store.saveProfiles([first, second])

        let loaded = try store.loadProfiles()

        #expect(loaded.map(\.id) == [first.id, second.id])
        #expect(loaded.map(\.webDataStoreID) == [first.webDataStoreID, second.webDataStoreID])
        #expect(loaded.map(\.label) == ["alpha@example.com", "beta@example.com"])
        #expect(loaded.map(\.emailLink) == [nil, "https://mail.google.com"])
        #expect(loaded.map(\.expiresAt) == [nil, Date(timeIntervalSince1970: 1_779_097_600)])
        #expect(loaded.map(\.tags) == [[], [.active, .pending]])
        #expect(loaded.map(\.lastKnownState) == [.active, .needsLogin])
    }

    @Test
    func saveAndLoadProfilesPreservesOptionalDetails() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        var profile = sampleProfile(label: "owner@example.com", sortOrder: 0)
        profile.password = "temporary-password"
        profile.twoFactorCode = "JBSWY3DPEHPK3PXP"
        profile.phoneNumber = "+62 812 3456"
        profile.notes = "Expires after handoff"

        try store.saveProfiles([profile])
        let loaded = try #require(store.loadProfiles().first)

        #expect(loaded.password == profile.password)
        #expect(loaded.twoFactorCode == profile.twoFactorCode)
        #expect(loaded.phoneNumber == profile.phoneNumber)
        #expect(loaded.notes == profile.notes)
    }

    @Test
    func saveProfilesRemovesDuplicateIdentifiersAndKeepsFirstProfile() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        var current = sampleProfile(label: "current@example.com", sortOrder: 0)
        current.phoneNumber = "+62 812 3456"
        current.notes = "Keep this current copy"
        var staleDuplicate = current
        staleDuplicate.sortOrder = 1
        staleDuplicate.phoneNumber = nil
        staleDuplicate.notes = nil

        try store.saveProfiles([current, staleDuplicate])

        let loaded = try store.loadProfiles()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == current.id)
        #expect(loaded.first?.phoneNumber == current.phoneNumber)
        #expect(loaded.first?.notes == current.notes)
        #expect(loaded.first?.sortOrder == 0)
    }

    @Test
    func loadProfilesReportsDuplicateIdentifiersFromExistingFile() throws {
        let tempDirectory = makeTemporaryDirectory()
        let fileURL = tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        let store = ProfileCatalogStore(fileURL: fileURL)
        let current = sampleProfile(label: "current@example.com", sortOrder: 0)
        var duplicate = current
        duplicate.sortOrder = 1
        let data = try JSONEncoder().encode([current, duplicate])
        try data.write(to: fileURL, options: .atomic)

        let result = try store.loadProfilesWithReport()

        #expect(result.profiles.count == 1)
        #expect(result.profiles.first?.id == current.id)
        #expect(result.removedDuplicateCount == 1)
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
        #expect(loaded.first?.tags == [])
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
    expiresAt: Date? = nil,
    tags: [PlusProfileTag] = [],
    lastKnownState: PlusProfileStoredState = .unknown
) -> PlusProfile {
    let createdAt = Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder))

    return PlusProfile(
        id: UUID(),
        label: label,
        emailLink: emailLink,
        detectedNote: detectedNote,
        expiresAt: expiresAt,
        tags: tags,
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
