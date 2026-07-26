import AppKit
import SwiftUI
import Testing
@testable import CodexPlusBar

@MainActor
struct MenuBarRootViewTests {
    @Test
    func menuBarRootViewUsesInteractiveProfileRows() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = PlusProfile(
            id: UUID(),
            label: "alpha@example.com",
            emailLink: "https://mail.google.com",
            detectedNote: "Plus",
            tags: [],
            webDataStoreID: UUID(),
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_776_000_000),
            lastRefreshAt: nil,
            lastKnownState: .active
        )
        try store.saveProfiles([profile])

        let controller = PlusProfileController(
            catalogStore: store,
            autoStart: false
        )
        let (defaults, suiteName) = makeUserDefaults()
        let rootView = MenuBarRootView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
            userDefaults: defaults,
            openManagerWindow: { _ in },
            openEmailToolsWindow: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 484, height: 560)
        let window = hostInWindow(hostingView)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            window.orderOut(nil)
        }

        flushViewHierarchy(for: hostingView)

        let bodyDescription = String(reflecting: type(of: rootView.body))
        #expect(bodyDescription.contains("MenuBarProfileRow") == true)
        #expect(bodyDescription.contains("ProfileSearchField") == true)
    }

    @Test
    func menuBarRootViewExposesPanelZoomControls() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        try store.saveProfiles([])

        let controller = PlusProfileController(
            catalogStore: store,
            autoStart: false
        )
        let (defaults, suiteName) = makeUserDefaults()
        let rootView = MenuBarRootView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
            userDefaults: defaults,
            openManagerWindow: { _ in },
            openEmailToolsWindow: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 484, height: 560)
        let window = hostInWindow(hostingView)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            window.orderOut(nil)
        }

        flushViewHierarchy(for: hostingView)

        let bodyDescription = String(reflecting: type(of: rootView.body))
        #expect(bodyDescription.contains("MenuBarZoomControls") == true)
    }

    @Test
    func menuBarFooterExposesThemeSettingsAction() {
        let themeSettingsAction = MenuBarFooterAction.openThemeSettings

        #expect(MenuBarFooterAction.allCases.contains(themeSettingsAction))
        #expect(themeSettingsAction.symbolName == "gearshape")
        #expect(themeSettingsAction.helpText == "Open theme settings")
        #expect(themeSettingsAction.tone == .secondary)
    }

    @Test
    func filterPresentationUsesAllStateForMenuBarPanel() {
        let presentation = ProfileFilterBarPresentation(
            filter: ProfileFilter(),
            shownCount: 3,
            totalCount: 3,
            fullFiveHourLimitCount: 1,
            tagCounts: ProfileTagCounts(active: 1, needAction: 1, pending: 1)
        )

        #expect(presentation.countText == "3 profiles")
        #expect(presentation.visibleSummaryText == "3 profiles")
        #expect(
            presentation.accessibilitySummaryText
                == "3 profiles, 1 profile with full 5-hour limit, 1 active, 1 need action, 1 pending"
        )
        #expect(
            presentation.segments.map(\.displayText)
                == ["All 3", "Full 1", "Active 1", "Action 1", "Pending 1"]
        )
        #expect(presentation.isAllSelected)
        #expect(presentation.isFullFiveHourLimitSelected == false)
        #expect(presentation.isSelected(.active) == false)
    }

    @Test
    func filterPresentationDisablesEmptyUnselectedSegments() throws {
        let presentation = ProfileFilterBarPresentation(
            filter: ProfileFilter([.active]),
            shownCount: 2,
            totalCount: 3,
            tagCounts: ProfileTagCounts(active: 2, needAction: 0, pending: 1)
        )

        let fullLimit = try #require(presentation.segments.first { $0.kind == .fullFiveHourLimit })
        let active = try #require(presentation.segments.first { $0.tag == .active })
        let needAction = try #require(presentation.segments.first { $0.tag == .needAction })

        #expect(presentation.visibleSummaryText == "2 of 3 shown")
        #expect(fullLimit.displayText == "Full 0")
        #expect(fullLimit.kind.systemImage == "gauge.high")
        #expect(fullLimit.accessibilityLabel == "Full 5-hour limit, 100 percent remaining")
        #expect(fullLimit.isSelected == false)
        #expect(fullLimit.isEnabled == false)
        #expect(active.displayText == "Active 2")
        #expect(active.isSelected)
        #expect(active.isEnabled)
        #expect(needAction.displayText == "Action 0")
        #expect(needAction.accessibilityLabel == "Need action")
        #expect(needAction.isSelected == false)
        #expect(needAction.isEnabled == false)
    }

    @Test
    func fullLimitFilterSegmentShowsExactSelectedState() throws {
        let presentation = ProfileFilterBarPresentation(
            filter: ProfileFilter(showsOnlyFullFiveHourLimit: true),
            shownCount: 2,
            totalCount: 5,
            fullFiveHourLimitCount: 2
        )

        let fullLimit = try #require(presentation.segments.first { $0.kind == .fullFiveHourLimit })

        #expect(presentation.isAllSelected == false)
        #expect(presentation.isFullFiveHourLimitSelected)
        #expect(fullLimit.displayText == "Full 2")
        #expect(fullLimit.isSelected)
        #expect(fullLimit.isEnabled)
    }

    @Test
    func menuBarFilteredProfilesUseSelectedAccountExpiryDisplayOrder() {
        let controller = PlusProfileController(
            dataService: StubMenuBarRootViewDataService(),
            autoStart: false
        )
        let (defaults, suiteName) = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        ProfileDisplayOrderPreference.setOrder(.accountExpiry, defaults: defaults)

        controller.profiles = [
            menuBarTestSnapshot(
                label: "unknown@example.com",
                state: .ready,
                fiveHourRemainingPercent: 50,
                sevenDayRemainingPercent: 50,
                sortOrder: 0,
                tags: [.active]
            ),
            menuBarTestSnapshot(
                label: "later@example.com",
                state: .ready,
                fiveHourRemainingPercent: 50,
                sevenDayRemainingPercent: 50,
                sortOrder: 1,
                expiresAt: Date(timeIntervalSince1970: 1_781_049_600),
                tags: [.active]
            ),
            menuBarTestSnapshot(
                label: "soonest@example.com",
                state: .ready,
                fiveHourRemainingPercent: 50,
                sevenDayRemainingPercent: 50,
                sortOrder: 2,
                expiresAt: Date(timeIntervalSince1970: 1_780_876_800),
                tags: [.active]
            ),
        ]

        let view = MenuBarRootView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
            userDefaults: defaults,
            openManagerWindow: { _ in },
            openEmailToolsWindow: {}
        )

        #expect(view.displayProfiles(for: ProfileFilter([.active])).map(\.label) == [
            "soonest@example.com",
            "later@example.com",
            "unknown@example.com",
        ])

        #expect(
            view.displayProfiles(
                for: ProfileFilter([.active]),
                query: "soonest@"
            ).map(\.label) == ["soonest@example.com"]
        )
    }

    @Test
    func menuBarProfilesDefaultToSoonestNextReset() {
        let controller = PlusProfileController(
            dataService: StubMenuBarRootViewDataService(),
            autoStart: false
        )
        let (defaults, suiteName) = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        controller.profiles = [
            menuBarTestSnapshot(
                label: "unknown@example.com",
                state: .idle,
                fiveHourRemainingPercent: nil,
                sevenDayRemainingPercent: nil,
                sortOrder: 0
            ),
            menuBarTestSnapshot(
                label: "later@example.com",
                state: .ready,
                fiveHourRemainingPercent: 50,
                sevenDayRemainingPercent: 50,
                sortOrder: 1,
                primaryResetAt: Date(timeIntervalSince1970: 1_776_021_600)
            ),
            menuBarTestSnapshot(
                label: "soonest@example.com",
                state: .ready,
                fiveHourRemainingPercent: 50,
                sevenDayRemainingPercent: 50,
                sortOrder: 2,
                primaryResetAt: Date(timeIntervalSince1970: 1_776_028_800),
                secondaryResetAt: Date(timeIntervalSince1970: 1_776_007_200)
            ),
        ]

        let view = MenuBarRootView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
            userDefaults: defaults,
            openManagerWindow: { _ in },
            openEmailToolsWindow: {}
        )

        #expect(view.displayProfiles(for: ProfileFilter()).map(\.label) == [
            "soonest@example.com",
            "later@example.com",
            "unknown@example.com",
        ])
    }
}

@MainActor
private final class StubMenuBarRootViewDataService: PlusProfileDataServing {
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        fatalError("Not used in MenuBarRootViewTests")
    }

    func openChromeSignIn(for profile: PlusProfile) async throws {
    }

    func openChromeAccountPage(for profile: PlusProfile) async throws {
    }

    func openChromePasskeySetup(for profile: PlusProfile) async throws {
    }

    func syncChromeSession(for profile: PlusProfile) async throws {
    }

    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool {
        false
    }

    func closeChromeSignIn(for profile: PlusProfile) async {
    }

    func clearSession(for profile: PlusProfile) async throws {
    }

    func removeProfileData(for profile: PlusProfile) async throws {
    }
}

private func menuBarTestSnapshot(
    label: String,
    state: PlusProfileState,
    fiveHourRemainingPercent: Int?,
    sevenDayRemainingPercent: Int?,
    sortOrder: Int,
    expiresAt: Date? = nil,
    tags: [PlusProfileTag] = [],
    primaryResetAt: Date = Date(timeIntervalSince1970: 1_776_018_000),
    secondaryResetAt: Date = Date(timeIntervalSince1970: 1_776_086_400)
) -> PlusProfileSnapshot {
    let usage: PlusProfileUsage? = if let fiveHourRemainingPercent {
        PlusProfileUsage(
            accountID: "acct-\(sortOrder)",
            planType: "chatgpt_plus",
            primaryWindow: WorkspaceLimitWindow(
                usedPercent: 100 - fiveHourRemainingPercent,
                resetAt: primaryResetAt
            ),
            secondaryWindow: sevenDayRemainingPercent.map {
                WorkspaceLimitWindow(
                    usedPercent: 100 - $0,
                    resetAt: secondaryResetAt
                )
            },
            fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
        )
    } else {
        nil
    }

    return PlusProfileSnapshot(
        profile: PlusProfile(
            id: UUID(),
            label: label,
            emailLink: nil,
            detectedNote: "Plus",
            expiresAt: expiresAt,
            tags: tags,
            webDataStoreID: UUID(),
            sortOrder: sortOrder,
            createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
            lastRefreshAt: nil,
            lastKnownState: state.storedState
        ),
        state: state,
        usage: usage,
        statusMessage: nil,
        isRefreshing: false
    )
}

@MainActor
private func hostInWindow(_ hostingView: NSHostingView<MenuBarRootView>) -> NSWindow {
    let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    return window
}

@MainActor
private func flushViewHierarchy(for hostingView: NSHostingView<MenuBarRootView>) {
    hostingView.layoutSubtreeIfNeeded()

    for _ in 0..<3 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
    }
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeUserDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "CodexPlusBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
