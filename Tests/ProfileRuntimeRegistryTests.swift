import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct ProfileRuntimeRegistryTests {
    @Test func restoringSameProfileUsesItsNewCookieStore() async throws {
        let original = sampleProfile(label: "restore@example.com", sortOrder: 0)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["webDataStoreID"] = UUID().uuidString
        let restored = try JSONDecoder().decode(PlusProfile.self, from: JSONSerialization.data(withJSONObject: json))
        let registry = ProfileRuntimeRegistry()
        let oldRuntime = registry.runtime(for: original)
        await oldRuntime.sessionStore.storeCookies([try #require(testCookie(name: "session", value: "old"))])
        try await BackupSessionBridge.restoreCookies([restored.id.uuidString: [
            BackupCookie(name: "session", value: "restored", domain: "chatgpt.com", path: "/", secure: true,
                         httpOnly: true, expires: nil, sameSite: nil)
        ]], profiles: [restored])

        let restoredRuntime = registry.runtime(for: restored)
        #expect(restoredRuntime !== oldRuntime)
        #expect(await restoredRuntime.sessionStore.cookieValue(named: "session") == "restored")
        #expect(registry.runtime(for: restored) === restoredRuntime)
        await oldRuntime.sessionStore.clear()
        await restoredRuntime.sessionStore.clear()
        _ = BackupSessionBridge.takeRestoredStore(for: restored.webDataStoreID)
        try? await registry.removeProfileData(for: original)
        try? await registry.removeProfileData(for: restored)
    }

    @Test
    func separateProfilesUseDifferentCookieStores() async throws {
        let profileA = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let profileB = sampleProfile(label: "beta@example.com", sortOrder: 1)
        let registry = ProfileRuntimeRegistry()

        let runtimeA = registry.runtime(for: profileA)
        _ = registry.runtime(for: profileB)
        let cookie = try #require(testCookie(name: "session-alpha", value: "cookie-a"))

        await runtimeA.sessionStore.storeCookies([cookie])

        #expect(await runtimeA.sessionStore.cookieValue(named: "session-alpha") == "cookie-a")
        #expect(await registry.runtime(for: profileB).sessionStore.cookieValue(named: "session-alpha") == nil)

        try? await registry.removeProfileData(for: profileA)
        try? await registry.removeProfileData(for: profileB)
    }

    @Test
    func clearingOneProfileLeavesOtherProfileCookiesIntact() async throws {
        let profileA = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let profileB = sampleProfile(label: "beta@example.com", sortOrder: 1)
        let registry = ProfileRuntimeRegistry()
        let runtimeA = registry.runtime(for: profileA)
        let runtimeB = registry.runtime(for: profileB)
        let cookieA = try #require(testCookie(name: "session-a", value: "alpha"))
        let cookieB = try #require(testCookie(name: "session-b", value: "beta"))

        await runtimeA.sessionStore.storeCookies([cookieA])
        await runtimeB.sessionStore.storeCookies([cookieB])

        await registry.clearSession(for: profileA)

        #expect(await runtimeA.sessionStore.cookieValue(named: "session-a") == nil)
        #expect(await runtimeB.sessionStore.cookieValue(named: "session-b") == "beta")

        try? await registry.removeProfileData(for: profileA)
        try? await registry.removeProfileData(for: profileB)
    }

    @Test
    func removingProfileDelegatesDataStoreDeletion() async throws {
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let manager = SpyProfileDataStoreManager()
        let registry = ProfileRuntimeRegistry(dataStoreManager: manager)

        _ = registry.runtime(for: profile)
        try await registry.removeProfileData(for: profile)

        #expect(manager.removedIdentifiers == [profile.webDataStoreID])
    }
}

@MainActor
private final class SpyProfileDataStoreManager: ProfileDataStoreManaging {
    private(set) var removedIdentifiers: [UUID] = []

    func dataStore(for identifier: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore.nonPersistent()
    }

    func removeDataStore(for identifier: UUID) async throws {
        removedIdentifiers.append(identifier)
    }
}

private func testCookie(name: String, value: String) -> HTTPCookie? {
    HTTPCookie(
        properties: [
            .name: name,
            .value: value,
            .domain: "chatgpt.com",
            .path: "/",
            .secure: "TRUE",
        ]
    )
}

private func sampleProfile(label: String, sortOrder: Int) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: label,
        emailLink: nil,
        detectedNote: nil,
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}
