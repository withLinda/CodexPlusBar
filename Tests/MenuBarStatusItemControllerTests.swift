import AppKit
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct MenuBarStatusItemControllerTests {
    @Test
    func statusItemLeavesTitleColorToTheSystemMenuBarContrast() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let controller = PlusProfileController(
            catalogStore: store,
            autoStart: false
        )
        let clock = AppMinuteClock()
        let statusController = MenuBarStatusItemController(
            controller: controller,
            clock: clock,
            openManagerWindow: { _ in },
            openEmailToolsWindow: {}
        )

        statusController.start()

        let statusItem = try #require(storedValue(in: statusController, as: NSStatusItem.self))
        defer {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        let button = try #require(statusItem.button)
        let attributedTitle = button.attributedTitle
        let titleColor = attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil)

        #expect(button.title == " Add profile")
        #expect(attributedTitle.string == " Add profile")
        #expect(titleColor == nil)
    }

    @Test
    func statusItemUsesStoredPinnedProfileSummary() async throws {
        let (defaults, suiteName) = makeUserDefaults()
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let preferred = sampleStoredProfile(label: "putrigildarahimah13@gmail.com", sortOrder: 0)
        let urgent = sampleStoredProfile(label: "urgent@example.com", sortOrder: 1)
        try store.saveProfiles([preferred, urgent])
        MenuBarProfilePreference.setPreferredProfileID(preferred.id, defaults: defaults)

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPinnedStatusDataService(
                refreshResults: [
                    preferred.id: makePinnedStatusUsage(
                        accountID: "acct_preferred",
                        fiveHourRemainingPercent: 74,
                        sevenDayRemainingPercent: 42
                    ),
                    urgent.id: makePinnedStatusUsage(
                        accountID: "acct_urgent",
                        fiveHourRemainingPercent: 11,
                        sevenDayRemainingPercent: 35
                    ),
                ]
            ),
            autoStart: false
        )
        let clock = AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000))
        let statusController = MenuBarStatusItemController(
            controller: controller,
            clock: clock,
            userDefaults: defaults,
            openManagerWindow: { _ in },
            openEmailToolsWindow: {}
        )

        await controller.refreshAll()

        statusController.start()

        let statusItem = try #require(storedValue(in: statusController, as: NSStatusItem.self))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        let button = try #require(statusItem.button)
        let attributedTitle = button.attributedTitle
        var titleRange = NSRange(location: 0, length: 0)
        let titleColor = attributedTitle.attribute(
            NSAttributedString.Key.foregroundColor,
            at: 0,
            effectiveRange: &titleRange
        )
        let visibleTitle = attributedTitle.string

        #expect(visibleTitle.contains("putrig**ah13@gma"))
        #expect(visibleTitle.contains("74%"))
        #expect(visibleTitle.contains("42%"))
        #expect(visibleTitle.contains("5H") == false)
        #expect(visibleTitle.contains("7D") == false)
        #expect(button.accessibilityLabel() == "CodexPlusBar putrig**ah13@gma, 5 hour 74%, 7 day 42%")
        #expect(titleColor == nil)
    }

    @Test
    func statusItemClearsMissingPinnedProfileAndFallsBackToUrgentSummary() async throws {
        let (defaults, suiteName) = makeUserDefaults()
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let urgent = sampleStoredProfile(label: "urgentprofile@example.com", sortOrder: 0)
        try store.saveProfiles([urgent])
        MenuBarProfilePreference.setPreferredProfileID(UUID(), defaults: defaults)

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPinnedStatusDataService(
                refreshResults: [
                    urgent.id: makePinnedStatusUsage(
                        accountID: "acct_urgent",
                        fiveHourRemainingPercent: 11,
                        sevenDayRemainingPercent: 35
                    ),
                ]
            ),
            autoStart: false
        )
        let clock = AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000))
        let statusController = MenuBarStatusItemController(
            controller: controller,
            clock: clock,
            userDefaults: defaults,
            openManagerWindow: { _ in },
            openEmailToolsWindow: {}
        )

        await controller.refreshAll()

        statusController.start()

        let statusItem = try #require(storedValue(in: statusController, as: NSStatusItem.self))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        let button = try #require(statusItem.button)
        let visibleTitle = button.attributedTitle.string

        #expect(visibleTitle.contains("urgent**file@exa"))
        #expect(visibleTitle.contains("11%"))
        #expect(visibleTitle.contains("35%"))
        #expect(visibleTitle.contains("5H") == false)
        #expect(visibleTitle.contains("7D") == false)
        #expect(button.accessibilityLabel() == "CodexPlusBar urgent**file@exa, 5 hour 11%, 7 day 35%")
        #expect(MenuBarProfilePreference.preferredProfileID(defaults: defaults, validProfileIDs: [urgent.id]) == nil)
    }
}

private func storedValue<Value>(in instance: Any, as type: Value.Type = Value.self) -> Value? {
    Mirror(reflecting: instance).children
        .compactMap { $0.value as? Value }
        .first
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private final class StubPinnedStatusDataService: PlusProfileDataServing {
    private let refreshResults: [UUID: PlusProfileUsage]

    init(refreshResults: [UUID: PlusProfileUsage]) {
        self.refreshResults = refreshResults
    }

    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        let usage = try #require(refreshResults[profile.id])
        return PlusProfileRefreshResult(usage: usage, detectedNote: "Chatgpt Plus")
    }

    func openChromeSignIn(for profile: PlusProfile) async throws {
    }

    func openChromePasskeySetup(for profile: PlusProfile) async throws {
    }

    func syncChromeSession(for profile: PlusProfile) async throws -> ChatGPTAuthContext {
        ChatGPTAuthContext(
            accessToken: "token-\(profile.id.uuidString)",
            accountID: "acct-\(profile.id.uuidString)",
            expiresAt: nil,
            deviceID: nil,
            clientVersion: nil,
            language: "en-US"
        )
    }

    func closeChromeSignIn(for profile: PlusProfile) async {
    }

    func clearSession(for profile: PlusProfile) async throws {
    }

    func removeProfileData(for profile: PlusProfile) async throws {
    }
}

private func sampleStoredProfile(label: String, sortOrder: Int) -> PlusProfile {
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

private func makePinnedStatusUsage(
    accountID: String,
    fiveHourRemainingPercent: Int,
    sevenDayRemainingPercent: Int?
) -> PlusProfileUsage {
    PlusProfileUsage(
        accountID: accountID,
        planType: "chatgpt_plus",
        primaryWindow: WorkspaceLimitWindow(
            usedPercent: 100 - fiveHourRemainingPercent,
            limitWindowSeconds: 18_000,
            resetAfterSeconds: 900,
            resetAt: Date(timeIntervalSince1970: 1_776_000_900)
        ),
        secondaryWindow: sevenDayRemainingPercent.map {
            WorkspaceLimitWindow(
                usedPercent: 100 - $0,
                limitWindowSeconds: 604_800,
                resetAfterSeconds: 86_400,
                resetAt: Date(timeIntervalSince1970: 1_776_086_400)
            )
        },
        fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
    )
}

private func makeUserDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "CodexPlusBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
