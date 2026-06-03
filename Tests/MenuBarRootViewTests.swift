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
    func tagFilterPresentationUsesAllStateForMenuBarPanel() {
        let presentation = ProfileTagFilterBarPresentation(
            filter: ProfileTagFilter(),
            shownCount: 3,
            totalCount: 3,
            tagCounts: ProfileTagCounts(active: 1, needAction: 1, pending: 1)
        )

        #expect(presentation.countText == "3 profiles")
        #expect(presentation.visibleSummaryText == "3 profiles")
        #expect(presentation.accessibilitySummaryText == "3 profiles, 1 active, 1 need action, 1 pending")
        #expect(presentation.segments.map(\.displayText) == ["All 3", "Active 1", "Action 1", "Pending 1"])
        #expect(presentation.isAllSelected)
        #expect(presentation.isSelected(.active) == false)
    }

    @Test
    func tagFilterPresentationDisablesEmptyUnselectedSegments() throws {
        let presentation = ProfileTagFilterBarPresentation(
            filter: ProfileTagFilter([.active]),
            shownCount: 2,
            totalCount: 3,
            tagCounts: ProfileTagCounts(active: 2, needAction: 0, pending: 1)
        )

        let active = try #require(presentation.segments.first { $0.tag == .active })
        let needAction = try #require(presentation.segments.first { $0.tag == .needAction })

        #expect(presentation.visibleSummaryText == "2 of 3 shown")
        #expect(active.displayText == "Active 2")
        #expect(active.isSelected)
        #expect(active.isEnabled)
        #expect(needAction.displayText == "Action 0")
        #expect(needAction.accessibilityLabel == "Need action")
        #expect(needAction.isSelected == false)
        #expect(needAction.isEnabled == false)
    }
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

@MainActor
private extension NSView {
    func allSubviews() -> [NSView] {
        var descendants: [NSView] = []

        for child in subviews {
            descendants.append(child)
            descendants.append(contentsOf: child.allSubviews())
        }

        return descendants
    }
}
