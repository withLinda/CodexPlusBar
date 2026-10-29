import Foundation
import AppKit
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor struct BackupCoordinationTests {
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
        let cookie = try #require(BackupCookie(name: "sessionKey", value: "fixture-only", domain: ".claude.ai", path: "/",
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
}

@MainActor private final class BackupTestPanel {
    var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation = $0 }
    }
}
