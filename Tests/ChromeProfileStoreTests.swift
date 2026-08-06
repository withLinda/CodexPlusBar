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
                == "/tmp/CodexPlusBarChromeProfiles/Profile-11111111-2222-4333-8444-555555555555"
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

    @Test
    func migrateLegacyProfileMovesAccountDataAndDropsOldChromeRoot() throws {
        let root = makeTemporaryDirectory()
        let profile = sampleProfile()
        let store = ChromeProfileStore(rootDirectory: root)
        let legacyDirectory = root.appendingPathComponent(
            profile.webDataStoreID.uuidString,
            isDirectory: true
        )
        let legacyDefault = legacyDirectory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDefault, withIntermediateDirectories: true)
        try "cookie-data".write(
            to: legacyDefault.appendingPathComponent("Cookies", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let legacyExtensions = legacyDefault.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyExtensions, withIntermediateDirectories: true)
        try "extension-data".write(
            to: legacyExtensions.appendingPathComponent("payload", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let extensionStorage = legacyDefault
            .appendingPathComponent("Storage", isDirectory: true)
            .appendingPathComponent("ext", isDirectory: true)
            .appendingPathComponent("component-extension", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionStorage,
            withIntermediateDirectories: true
        )
        try "extension-cookie-data".write(
            to: extensionStorage.appendingPathComponent("Cookies", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "history-data".write(
            to: legacyDefault.appendingPathComponent("History", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: legacyDefault.appendingPathComponent("LOCK", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "{\"extensions\":{\"theme\":{\"id\":\"old-theme\"}},\"kept\":\"yes\"}".write(
            to: legacyDefault.appendingPathComponent("Preferences", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let securePreferences = "{\"account_values\":{\"keep\":true},\"google\":{\"keep\":true}}"
        try securePreferences.write(
            to: legacyDefault.appendingPathComponent("Secure Preferences", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let webApplicationIcon = legacyDefault
            .appendingPathComponent("Web Applications", isDirectory: true)
            .appendingPathComponent("Manifest Resources", isDirectory: true)
            .appendingPathComponent("example-app", isDirectory: true)
            .appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent("32.png", isDirectory: false)
        try FileManager.default.createDirectory(
            at: webApplicationIcon.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: webApplicationIcon)
        try "{\"profile\":{\"info_cache\":{\"Default\":{\"name\":\"Linda\"}},\"profiles_order\":[\"Default\"]}}"
            .write(
                to: legacyDirectory.appendingPathComponent("Local State", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        let browserMetrics = root.appendingPathComponent(
            "BrowserMetrics-spare.pma",
            isDirectory: false
        )
        try Data(repeating: 0, count: 16).write(to: browserMetrics)

        let report = try store.migrateAndPrune(profiles: [profile])
        let currentDirectory = store.profileDirectory(for: profile)

        #expect(report.migratedProfileCount == 1)
        #expect(FileManager.default.fileExists(atPath: currentDirectory.path))
        #expect(FileManager.default.fileExists(atPath: legacyDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: browserMetrics.path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: currentDirectory.appendingPathComponent("Cookies").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: currentDirectory.appendingPathComponent("Extensions").path
            ) == false
        )
        #expect(
            FileManager.default.fileExists(
                atPath: currentDirectory
                    .appendingPathComponent("Storage", isDirectory: true)
                    .appendingPathComponent("ext", isDirectory: true)
                    .path
            ) == false
        )
        #expect(
            FileManager.default.fileExists(
                atPath: currentDirectory.appendingPathComponent("History").path
            ) == false
        )
        #expect(
            FileManager.default.fileExists(
                atPath: currentDirectory.appendingPathComponent("LOCK").path
            ) == false
        )

        let preferencesData = try Data(
            contentsOf: currentDirectory.appendingPathComponent("Preferences", isDirectory: false)
        )
        let preferences = try #require(
            JSONSerialization.jsonObject(with: preferencesData) as? [String: Any]
        )
        let extensions = try #require(preferences["extensions"] as? [String: Any])
        #expect(extensions["theme"] == nil)
        #expect(preferences["kept"] as? String == "yes")
        #expect(
            try String(
                contentsOf: currentDirectory.appendingPathComponent(
                    "Secure Preferences",
                    isDirectory: false
                ),
                encoding: .utf8
            ) == securePreferences
        )
        #expect(
            FileManager.default.fileExists(
                atPath: currentDirectory
                    .appendingPathComponent("Web Applications", isDirectory: true)
                    .appendingPathComponent("Manifest Resources", isDirectory: true)
                    .appendingPathComponent("example-app", isDirectory: true)
                    .appendingPathComponent("Icons", isDirectory: true)
                    .appendingPathComponent("32.png", isDirectory: false)
                    .path
            )
        )

        let localStateData = try Data(
            contentsOf: root.appendingPathComponent("Local State", isDirectory: false)
        )
        let localState = try #require(
            JSONSerialization.jsonObject(with: localStateData) as? [String: Any]
        )
        let profileState = try #require(localState["profile"] as? [String: Any])
        let infoCache = try #require(profileState["info_cache"] as? [String: Any])
        #expect(infoCache[store.profileDirectoryName(for: profile)] != nil)
    }

    @Test
    func emptyCatalogNeverDeletesUnknownLegacyData() throws {
        let root = makeTemporaryDirectory()
        let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "keep-me".write(
            to: orphan.appendingPathComponent("marker", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        _ = try ChromeProfileStore(rootDirectory: root).migrateAndPrune(profiles: [])

        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test
    func migrationRemovesCatalogOrphansButKeepsProfileCookies() throws {
        let root = makeTemporaryDirectory()
        let profile = sampleProfile()
        let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "old-data".write(
            to: orphan.appendingPathComponent("marker", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let current = ChromeProfileStore(rootDirectory: root).profileDirectory(for: profile)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "cookie-data".write(
            to: current.appendingPathComponent("Cookies", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "preferences".write(
            to: current.appendingPathComponent("Preferences", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let extensions = current.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try "generated".write(
            to: extensions.appendingPathComponent("payload", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let report = try ChromeProfileStore(rootDirectory: root).migrateAndPrune(profiles: [profile])

        #expect(report.removedOrphanCount == 1)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("Cookies").path))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("Preferences").path))
        #expect(FileManager.default.fileExists(atPath: extensions.path) == false)
    }

    @Test
    func malformedLegacyLocalStateRollsAccountDataBackToTheOldLocation() throws {
        let root = makeTemporaryDirectory()
        let profile = sampleProfile()
        let store = ChromeProfileStore(rootDirectory: root)
        let legacyDirectory = root.appendingPathComponent(
            profile.webDataStoreID.uuidString,
            isDirectory: true
        )
        let legacyDefault = legacyDirectory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDefault, withIntermediateDirectories: true)
        try "cookie-data".write(
            to: legacyDefault.appendingPathComponent("Cookies", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "not-json".write(
            to: legacyDirectory.appendingPathComponent("Local State", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var didThrow = false
        do {
            _ = try store.migrateAndPrune(profiles: [profile])
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: legacyDefault.appendingPathComponent("Cookies").path))
        #expect(FileManager.default.fileExists(atPath: store.profileDirectory(for: profile).path) == false)
    }

    @Test
    func completedProfileMoveRemovesAStaleLegacyCacheWrapper() throws {
        let root = makeTemporaryDirectory()
        let profile = sampleProfile()
        let store = ChromeProfileStore(rootDirectory: root)
        let current = store.profileDirectory(for: profile)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "cookie-data".write(
            to: current.appendingPathComponent("Cookies", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let legacy = root.appendingPathComponent(
            profile.webDataStoreID.uuidString,
            isDirectory: true
        )
        let staleCache = legacy.appendingPathComponent("component_crx_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: staleCache, withIntermediateDirectories: true)
        try "generated".write(
            to: staleCache.appendingPathComponent("payload", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        _ = try store.ensureProfileDirectory(for: profile)

        #expect(FileManager.default.fileExists(atPath: legacy.path) == false)
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("Cookies").path))
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
