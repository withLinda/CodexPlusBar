import Foundation
import WebKit

@MainActor enum BackupSessionBridge {
    // Session-only cookies disappear when their WebKit store is released. Hold restored
    // stores until the normal runtime takes ownership, including after receipt replay.
    private static var restoredStores: [UUID: WKWebsiteDataStore] = [:]

    static func takeRestoredStore(for identifier: UUID) -> WKWebsiteDataStore? {
        restoredStores.removeValue(forKey: identifier)
    }

    static func collectCookies(profiles: [PlusProfile]) async -> [String: [BackupCookie]] {
        var result: [String: [BackupCookie]] = [:]
        for profile in profiles {
            let store = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
            let cookies = await store.httpCookieStore.allCookies().map(BackupCookie.init)
            result[profile.id.uuidString] = cookies.filter { $0.isValid(for: profile.provider) }
        }
        return result
    }

    static func restoreCookies(_ cookies: [String: [BackupCookie]], profiles: [PlusProfile]) async throws {
        for profile in profiles {
            let store = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
            restoredStores[profile.webDataStoreID] = store
            for record in cookies[profile.id.uuidString] ?? [] {
                guard record.isValid(for: profile.provider), let cookie = record.cookie else { throw BackupError.invalidData }
                if let expires = record.expires, expires < .now { continue }
                await store.httpCookieStore.setCookie(cookie)
            }
        }
    }

    static func preferences(in defaults: UserDefaults = .standard) -> BackupPreferences {
        BackupPreferences(appearance: defaults.string(forKey: CodexThemeSettings.Keys.appearanceMode),
                          contrast: defaults.string(forKey: CodexThemeSettings.Keys.contrast),
                          displayOrder: defaults.string(forKey: ProfileDisplayOrderPreference.orderKey),
                          pinnedProfile: defaults.string(forKey: MenuBarProfilePreference.preferredProfileIDKey),
                          textScale: defaults.object(forKey: MenuBarPanelTextScalePreference.textScaleKey) as? Double,
                          automaticSync: defaults.object(forKey: OpenChamberSyncPreference.enabledKey) as? Bool)
    }

    static func apply(_ preferences: BackupPreferences, to defaults: UserDefaults = .standard) throws {
        try preferences.validate()
        defaults.set(preferences.appearance, forKey: CodexThemeSettings.Keys.appearanceMode)
        defaults.set(preferences.contrast, forKey: CodexThemeSettings.Keys.contrast)
        defaults.set(preferences.displayOrder, forKey: ProfileDisplayOrderPreference.orderKey)
        defaults.set(preferences.pinnedProfile, forKey: MenuBarProfilePreference.preferredProfileIDKey)
        defaults.set(preferences.textScale, forKey: MenuBarPanelTextScalePreference.textScaleKey)
        defaults.set(preferences.automaticSync, forKey: OpenChamberSyncPreference.enabledKey)
    }

    /// Receipt lives in the atomically installed tree. Replaying after a crash is idempotent.
    static func finishRestore(root: URL = ProfileCatalogStore.defaultFileURL().deletingLastPathComponent(), defaults: UserDefaults = .standard) async throws {
        let receipt = root.appendingPathComponent(BackupService.receiptName)
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: receipt))
        let profiles = try ProfileCatalogStore(fileURL: root.appendingPathComponent("profiles.json")).loadProfiles()
        try manifest.validate(profiles: profiles)
        try await restoreCookies(manifest.cookies, profiles: profiles)
        try apply(manifest.preferences, to: defaults)
        guard defaults.synchronize() else { throw BackupError.storage }
        try FileManager.default.removeItem(at: receipt)
    }
}
