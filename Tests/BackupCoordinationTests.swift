import Foundation
import AppKit
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor struct BackupCoordinationTests {
    @Test(arguments: [false, true])
    func exportCountsInactiveRecordsButOnlyCollectsCodexSessions(onlyLegacy: Bool) async throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileCatalogStore(fileURL: root.appendingPathComponent("profiles.json"))
        let legacy = try legacyTestProfile()
        let codex = backupTestProfile()
        try store.saveProfiles(onlyLegacy ? [legacy] : [codex, legacy])
        let profiles = PlusProfileController(catalogStore: store, autoStart: false)
        let transfer = BackupTransferController(profiles: profiles,
            email: DotTrickController(store: .init(fileURL: root.appendingPathComponent("email.json"))), root: root)
        let manifest = await transfer.captureManifest()
        #expect(transfer.replacesExistingData)
        #expect(manifest.profileCount == (onlyLegacy ? 1 : 2))
        #expect(manifest.cookies[legacy.id.uuidString] == nil)
        #expect(manifest.cookies.count == (onlyLegacy ? 0 : 1))
        let service = BackupService(root: root)
        let archive = root.appendingPathComponent("test.backup")
        try await service.export(to: archive, password: "test backup password", manifest: manifest)
        let prepared = try await service.prepare(from: archive, password: "test backup password")
        #expect(prepared.manifest.profileCount == manifest.profileCount)
        await service.discard(prepared)
        if !onlyLegacy { try? await WKWebsiteDataStore.remove(forIdentifier: codex.webDataStoreID) }
    }

    @Test func nativePanelOwnsTheWorkflowUntilItCloses() async throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = PlusProfileController(catalogStore: .init(fileURL: root.appendingPathComponent("profiles.json")), autoStart: false)
        let email = DotTrickController(store: .init(fileURL: root.appendingPathComponent("email.json")))
        let panel = BackupTestPanel()
        let transfer = BackupTransferController(profiles: profiles, email: email, root: root, panelPresenter: panel.present)
        transfer.password = "test password"; transfer.confirmation = "test password"
        transfer.submitPassword()
        while panel.continuation == nil { await Task.yield() }
        #expect(transfer.isBusy)
        transfer.begin(.export)
        #expect(transfer.password == "test password")
        panel.continuation?.resume(returning: .cancel)
        while transfer.isBusy { await Task.yield() }
        #expect(!profiles.isTransferring)
    }

    @Test func pendingRestoreCannotBeResetFromAnotherEntryPoint() async throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = PlusProfileController(catalogStore: .init(fileURL: root.appendingPathComponent("profiles.json")), autoStart: false)
        let transfer = BackupTransferController(profiles: profiles,
            email: DotTrickController(store: .init(fileURL: root.appendingPathComponent("email.json"))), root: root)
        try await profiles.pauseForBackup()
        transfer.phase = .recoveryNeeded
        transfer.begin(.export)
        #expect({ if case .recoveryNeeded = transfer.phase { return true }; return false }())
        profiles.resumeAfterBackup(reload: false, startTasks: false)
    }

    @Test func portableSessionRoundTripRetainsHttpOnlyAndNeverTouchesUnrelatedDomains() async throws {
        let profile = backupTestProfile()
        let store = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
        let cookie = try #require(BackupCookie(name: "sessionKey", value: "fixture-only", domain: ".chatgpt.com", path: "/",
                                             secure: true, httpOnly: true, expires: Date().addingTimeInterval(3600), sameSite: "Lax").cookie)
        await store.httpCookieStore.setCookie(cookie)
        let foreign = try #require(HTTPCookie(properties: [.name: "private", .value: "do-not-export", .domain: "example.com", .path: "/"]))
        await store.httpCookieStore.setCookie(foreign)
        let values = await BackupSessionBridge.collectCookies(profiles: [profile])
        #expect(values[profile.id.uuidString]?.map(\.name) == ["sessionKey"])
        #expect(values[profile.id.uuidString]?.first?.httpOnly == true)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try await BackupSessionBridge.restoreCookies(values, profiles: [profile])
        let restored = await store.httpCookieStore.allCookies()
        #expect(restored.count == 1)
        #expect(restored.first?.value == "fixture-only")
        #expect(restored.first?.isHTTPOnly == true)
        _ = BackupSessionBridge.takeRestoredStore(for: profile.webDataStoreID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: profile.webDataStoreID)
    }

    @Test func preferencesTransferOnlyAppOwnedSettingsAndClearMissingValues() throws {
        let name = "BackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: CodexThemeSettings.Keys.appearanceMode)
        defaults.set("leave-me", forKey: "UnrelatedValue")
        let preferences = BackupSessionBridge.preferences(in: defaults)
        #expect(preferences.appearance == "dark")
        defaults.set("soft", forKey: CodexThemeSettings.Keys.contrast)
        try BackupSessionBridge.apply(preferences, to: defaults)
        #expect(defaults.object(forKey: CodexThemeSettings.Keys.contrast) == nil)
        #expect(defaults.string(forKey: "UnrelatedValue") == "leave-me")
    }

    @Test func canvasChoiceSurvivesBackupEncodingAndRestore() throws {
        let name = "BackupCanvasTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "CodexPlusBar.theme.canvas"

        for choice in ["original", "dim", "deep"] {
            defaults.set(choice, forKey: key)
            let data = try JSONEncoder().encode(BackupSessionBridge.preferences(in: defaults))
            defaults.removeObject(forKey: key)
            let restored = try JSONDecoder().decode(BackupPreferences.self, from: data)
            try BackupSessionBridge.apply(restored, to: defaults)
            #expect(defaults.string(forKey: key) == choice)
        }
    }

    @Test func oldBackupUsesDefaultCanvasAndInvalidCanvasIsRejectedBeforeApplying() throws {
        let name = "BackupCanvasTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("original", forKey: CodexThemeSettings.Keys.canvas)
        let legacy = try JSONDecoder().decode(BackupPreferences.self, from: Data(#"{"appearance":"dark","contrast":"hard"}"#.utf8))
        try BackupSessionBridge.apply(legacy, to: defaults)
        #expect(CodexThemeSettings.canvas(in: defaults) == .deep)

        let invalid = try JSONDecoder().decode(BackupPreferences.self, from: Data(#"{"appearance":"light","canvas":"unknown"}"#.utf8))
        #expect(throws: BackupError.invalidData) { try BackupSessionBridge.apply(invalid, to: defaults) }
        #expect(CodexThemeSettings.appearanceMode(in: defaults) == .dark)
    }
}

@MainActor private final class BackupTestPanel {
    var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation = $0 }
    }
}
