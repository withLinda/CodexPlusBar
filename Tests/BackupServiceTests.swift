import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

struct BackupServiceTests {
    @Test @MainActor
    func mixedLegacyBackupRestoresRecordsWithoutActivatingLegacyCookies() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("restored")
        var codex = backupTestProfile()
        codex.provider = .codex
        let legacy = try legacyTestProfile()
        try ProfileCatalogStore(fileURL: source.appendingPathComponent("profiles.json")).saveProfiles([codex, legacy])
        let cookies = [legacy.id.uuidString: [BackupCookie(name: "sessionKey", value: "inactive-cookie",
            domain: ".claude.ai", path: "/", secure: true, httpOnly: true, expires: nil, sameSite: nil)]]
        let archive = base.appendingPathComponent("mixed.backup")
        try await BackupService(root: source).export(to: archive, password: "test backup password",
            manifest: .init(profileCount: 2, preferences: .init(), cookies: cookies))
        let importer = BackupService(root: destination)
        let prepared = try await importer.prepare(from: archive, password: "test backup password")
        try await importer.commit(prepared)
        let suite = "LegacyBackup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await BackupSessionBridge.finishRestore(root: destination, defaults: defaults)
        let restored = try ProfileCatalogStore(fileURL: destination.appendingPathComponent("profiles.json")).loadProfiles()
        let inactive = try #require(restored.first(where: { $0.id == legacy.id }))
        #expect(restored.count == 2)
        #expect(inactive.provider.rawValue == "claude")
        #expect(inactive.notes == legacy.notes)
        #expect(BackupSessionBridge.takeRestoredStore(for: inactive.webDataStoreID) == nil)
        if let active = restored.first(where: { $0.id == codex.id }) {
            #expect(BackupSessionBridge.takeRestoredStore(for: active.webDataStoreID) != nil)
            try await WKWebsiteDataStore.remove(forIdentifier: active.webDataStoreID)
        }
        try await WKWebsiteDataStore.remove(forIdentifier: inactive.webDataStoreID)
    }

    @Test func repairedDesktopVaultStillExportsAndRestores() async throws {
        let f = try NativeSwitchFixture(); defer { f.cleanUp() }
        let profile = try f.installTarget()
        let signIn = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "repaired"))
        try await f.service.installRepaired(signIn, for: profile)
        let source = f.vault.directory.deletingLastPathComponent()
        try ProfileCatalogStore(fileURL: source.appendingPathComponent("profiles.json")).saveProfiles([profile])
        let archive = f.home.appendingPathComponent("backup")
        try await BackupService(root: source).export(to: archive, password: "test backup password",
            manifest: .init(profileCount: 1, preferences: .init(), cookies: [:]))
        let restoredHome = f.home.appendingPathComponent("restored")
        let restoredVault = CodexSignInVault(homeDirectory: restoredHome)
        let importer = BackupService(root: restoredVault.directory.deletingLastPathComponent())
        let prepared = try await importer.prepare(from: archive, password: "test backup password")
        try await importer.commit(prepared)
        #expect(try restoredVault.load(signIn.identity) == signIn)
        #expect(restoredVault.hasRepairReceipt(for: signIn))
    }

    @Test func oversizedPortableSessionsCannotProduceAnUnrestorableExport() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let profiles = (0..<8).map { _ in backupTestProfile() }
        let root = base.appendingPathComponent("source")
        try ProfileCatalogStore(fileURL: root.appendingPathComponent("profiles.json")).saveProfiles(profiles)
        let cookies = (0..<1_000).map { index in
            BackupCookie(name: "cookie-\(index)", value: String(repeating: "x", count: 2_560), domain: ".chatgpt.com",
                         path: "/", secure: true, httpOnly: true, expires: nil, sameSite: nil)
        }
        let file = base.appendingPathComponent("existing")
        try Data("previous backup".utf8).write(to: file)
        let manifest = BackupManifest(profileCount: profiles.count, preferences: .init(),
            cookies: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString, cookies) }))
        try manifest.validate(profiles: profiles)
        await #expect(throws: BackupError.tooLarge) {
            try await BackupService(root: root).export(to: file, password: "test password", manifest: manifest)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "previous backup")
    }

    @Test func oversizedEmailAndChromeMetadataAreRejectedBeforeCommit() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("destination")
        let existing = backupTestProfile()
        let catalog = destination.appendingPathComponent("profiles.json")
        try ProfileCatalogStore(fileURL: catalog).saveProfiles([existing])
        let before = try Data(contentsOf: catalog)
        let service = BackupService(root: destination)
        for path in ["dot-trick-sessions.json", "ChromeProfiles/Local State"] {
            let source = base.appendingPathComponent(UUID().uuidString)
            let data = source.appendingPathComponent("Data")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: data.appendingPathComponent("profiles.json"))
            try JSONEncoder().encode(BackupManifest(profileCount: 0, preferences: .init(), cookies: [:]))
                .write(to: source.appendingPathComponent("manifest.json"))
            let oversized = data.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: oversized.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((path.hasPrefix("Chrome") ? "{}" : "[]").utf8).write(to: oversized)
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.seekToEnd()
            for _ in 0..<65 { try handle.write(contentsOf: Data(repeating: 32, count: 1_024 * 1_024)) }
            try handle.close()
            let file = base.appendingPathComponent("oversized")
            try BackupArchive.encode(directory: source, to: file, password: "test password")
            await #expect(throws: BackupError.tooLarge) { try await service.prepare(from: file, password: "test password") }
            #expect(try Data(contentsOf: catalog) == before)
        }
    }

    @Test func cancelledCommitKeepsDestinationAndAllowsValidatedRetry() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old/CodexPlusBar"), destination = base.appendingPathComponent("new/CodexPlusBar")
        let old = backupTestProfile(), new = backupTestProfile()
        try ProfileCatalogStore(fileURL: source.appendingPathComponent("profiles.json")).saveProfiles([new])
        try ProfileCatalogStore(fileURL: destination.appendingPathComponent("profiles.json")).saveProfiles([old])
        let file = base.appendingPathComponent("transfer")
        try await BackupService(root: source).export(to: file, password: "test password", manifest: .init(profileCount: 1, preferences: .init(), cookies: [:]))
        let service = BackupService(root: destination)
        let prepared = try await service.prepare(from: file, password: "test password")
        let before = try Data(contentsOf: destination.appendingPathComponent("profiles.json"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.commit(prepared)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: destination.appendingPathComponent("profiles.json")) == before)
        try await service.commit(prepared)
        #expect(try ProfileCatalogStore(fileURL: destination.appendingPathComponent("profiles.json")).loadProfiles().first?.id == new.id)
    }

    @Test @MainActor func restoreReceiptReplaysSettingsAndCookiesAfterInterruptedLaunch() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("CodexPlusBar")
        let profile = backupTestProfile()
        try ProfileCatalogStore(fileURL: root.appendingPathComponent("profiles.json")).saveProfiles([profile])
        let name = "backup-replay-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manifest = BackupManifest(profileCount: 1, preferences: BackupPreferences(appearance: "light"),
            cookies: [profile.id.uuidString: [BackupCookie(name: "sessionKey", value: "synthetic-replay", domain: ".chatgpt.com", path: "/", secure: true, httpOnly: true, expires: nil, sameSite: nil)]])
        let receipt = root.appendingPathComponent(BackupService.receiptName)
        try JSONEncoder().encode(manifest).write(to: receipt)
        try await BackupSessionBridge.finishRestore(root: root, defaults: defaults)
        try await BackupSessionBridge.finishRestore(root: root, defaults: defaults)
        #expect(defaults.string(forKey: CodexThemeSettings.Keys.appearanceMode) == "light")
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        let store = DefaultProfileDataStoreManager().dataStore(for: profile.webDataStoreID)
        let values = await store.httpCookieStore.allCookies()
        #expect(values.first?.value == "synthetic-replay")
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    @Test func fullTransferPreservesDetailsVaultsAndEmailToolsWithFreshCookieStores() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old/CodexPlusBar")
        let destination = base.appendingPathComponent("new/CodexPlusBar")
        let profile = backupTestProfile()
        try ProfileCatalogStore(fileURL: source.appendingPathComponent("profiles.json")).saveProfiles([profile])
        let emailSession = DotTrickSession(localPart: "backuptest", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                          usedVariations: ["backup.test"])
        try DotTrickSessionStore(fileURL: source.appendingPathComponent("dot-trick-sessions.json")).saveSessions([emailSession])
        for (path, value) in [("DesktopSignIns/test.json", "{\"token\":\"synthetic-desktop\"}"),
                              ("OpenChamberSignIns/test.rotations.json", "{\"rotation\":\"synthetic-refresh\"}"),
                              ("ChromeProfiles/Profile test/Cookies", "synthetic-browser-bytes"),
                              ("ChromeProfiles/Profile test/Cache/data", "disposable")] {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        let exporter = BackupService(root: source)
        let file = base.appendingPathComponent("transfer.codexplusbarbackup")
        let cookies = [profile.id.uuidString: [BackupCookie(name: "sessionKey", value: "synthetic-cookie", domain: ".chatgpt.com", path: "/", secure: true, httpOnly: true, expires: nil, sameSite: nil)]]
        let manifest = BackupManifest(profileCount: 1, preferences: .init(), cookies: cookies)
        try await exporter.export(to: file, password: "my backup password", manifest: manifest)
        let importer = BackupService(root: destination)
        let prepared = try await importer.prepare(from: file, password: "my backup password")
        #expect(prepared.manifest.profileCount == 1)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try await importer.commit(prepared)
        let profiles = try ProfileCatalogStore(fileURL: destination.appendingPathComponent("profiles.json")).loadProfiles()
        let restored = try #require(profiles.first)
        #expect(restored.id == profile.id)
        #expect(restored.webDataStoreID != profile.webDataStoreID)
        #expect(restored.password == "synthetic-password")
        #expect(restored.notes == "Keep all my notes\nincluding this line")
        #expect(restored.provider == .codex)
        #expect(restored.tags == [.pending])
        #expect(restored.phoneNumber == "+1 202 555 0123")
        #expect(try DotTrickSessionStore(fileURL: destination.appendingPathComponent("dot-trick-sessions.json")).loadSessions() == [emailSession])
        #expect(try String(contentsOf: destination.appendingPathComponent("DesktopSignIns/test.json"), encoding: .utf8).contains("synthetic-desktop"))
        #expect(try String(contentsOf: destination.appendingPathComponent("ChromeProfiles/Profile test/Cookies"), encoding: .utf8) == "synthetic-browser-bytes")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("ChromeProfiles/Profile test/Cache").path))
        let receipt = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: destination.appendingPathComponent("BackupRestore.json")))
        #expect(receipt.cookies[profile.id.uuidString]?.first?.value == "synthetic-cookie")
    }

    @Test func rejectedAndCancelledRestoresPreserveExistingCatalog() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("CodexPlusBar")
        let store = ProfileCatalogStore(fileURL: destination.appendingPathComponent("profiles.json"))
        let existing = backupTestProfile()
        try store.saveProfiles([existing])
        let before = try Data(contentsOf: destination.appendingPathComponent("profiles.json"))
        let bad = base.appendingPathComponent("bad.backup")
        try Data("not an archive".utf8).write(to: bad)
        let service = BackupService(root: destination)
        await #expect(throws: (any Error).self) { try await service.prepare(from: bad, password: "password") }
        #expect(try Data(contentsOf: destination.appendingPathComponent("profiles.json")) == before)
        let archive = base.appendingPathComponent("good.backup")
        try await service.export(to: archive, password: "long password", manifest: .init(profileCount: 1, preferences: .init(), cookies: [:]))
        let prepared = try await service.prepare(from: archive, password: "long password")
        await service.discard(prepared)
        await #expect(throws: (any Error).self) { try await service.commit(prepared) }
        #expect(try Data(contentsOf: destination.appendingPathComponent("profiles.json")) == before)
    }

    @Test func malformedCatalogAndUnknownSchemaCannotBeExportedOrRestored() async throws {
        let base = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("CodexPlusBar")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[broken".utf8).write(to: root.appendingPathComponent("profiles.json"))
        let service = BackupService(root: root)
        await #expect(throws: (any Error).self) {
            try await service.export(to: base.appendingPathComponent("bad"), password: "long password", manifest: .init(profileCount: 1, preferences: .init(), cookies: [:]))
        }
        var manifest = BackupManifest(profileCount: 0, preferences: .init(), cookies: [:])
        manifest.schemaVersion = 999
        #expect(throws: BackupError.unsupportedVersion) { try manifest.validate(profiles: []) }
        let duplicate = backupTestProfile()
        let m = BackupManifest(profileCount: 2, preferences: .init(), cookies: [:])
        #expect(throws: BackupError.invalidData) { try m.validate(profiles: [duplicate, duplicate]) }
    }
}

func backupTestProfile() -> PlusProfile {
    PlusProfile(id: UUID(), provider: .codex, label: "Backup test", emailLink: "https://example.com", detectedNote: nil,
                password: "synthetic-password", twoFactorCode: "JBSWY3DPEHPK3PXP", phoneNumber: "+1 202 555 0123",
                notes: "Keep all my notes\nincluding this line", tags: [.pending], webDataStoreID: UUID(), sortOrder: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastRefreshAt: nil, lastKnownState: .unknown)
}

// Archived provider values are data fixtures, not supported runtime providers.
func legacyTestProfile(provider: String = "claude") throws -> PlusProfile {
    let data = try JSONEncoder().encode(backupTestProfile())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["provider"] = provider
    object["sortOrder"] = 1
    return try JSONDecoder().decode(PlusProfile.self, from: JSONSerialization.data(withJSONObject: object))
}
