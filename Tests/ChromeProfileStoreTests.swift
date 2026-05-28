import Foundation
import Testing
@testable import CodexPlusBar

struct ChromeProfileStoreTests {
    @Test
    func profileDirectoryUsesExistingWebDataStoreIdentifier() {
        let root = URL(fileURLWithPath: "/tmp/CodexPlusBarChromeProfiles", isDirectory: true)
        let profile = sampleProfile(webDataStoreID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
        let store = ChromeProfileStore(rootDirectory: root)

        #expect(
            store.profileDirectory(for: profile).path
                == "/tmp/CodexPlusBarChromeProfiles/11111111-2222-4333-8444-555555555555"
        )
    }

    @Test
    func removeProfileDataDeletesProfileDirectory() throws {
        let root = makeTemporaryDirectory()
        let profile = sampleProfile()
        let store = ChromeProfileStore(rootDirectory: root)
        let profileDirectory = store.profileDirectory(for: profile)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try "cookie-data".write(
            to: profileDirectory.appendingPathComponent("Cookies", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        try store.removeProfileDirectory(for: profile)

        #expect(FileManager.default.fileExists(atPath: profileDirectory.path) == false)
    }
}

private func sampleProfile(webDataStoreID: UUID = UUID()) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: "alpha@example.com",
        emailLink: nil,
        detectedNote: nil,
        webDataStoreID: webDataStoreID,
        sortOrder: 0,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
