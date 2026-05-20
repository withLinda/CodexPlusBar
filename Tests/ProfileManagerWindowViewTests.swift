import AppKit
import SwiftUI
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct ProfileManagerWindowViewTests {
    @Test
    func sessionPaneBuildsWebViewOnlyWhenExpanded() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        try store.saveProfiles([profile])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubProfileViewDataService(),
            autoStart: false
        )
        let collapsedHostingView = makeHostingView(
            controller: controller,
            initialSessionExpanded: false
        )
        let expandedHostingView = makeHostingView(
            controller: controller,
            initialSessionExpanded: true
        )

        let collapsedWindow = hostInWindow(collapsedHostingView)
        let expandedWindow = hostInWindow(expandedHostingView)
        defer {
            collapsedWindow.orderOut(nil)
            expandedWindow.orderOut(nil)
        }

        flushViewHierarchy(for: collapsedHostingView)
        flushViewHierarchy(for: expandedHostingView)

        #expect(containsWebView(in: collapsedHostingView) == false)
        #expect(containsWebView(in: expandedHostingView))
    }

    @Test
    func selectedProfileHeaderBuildsTwoEditableFields() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(
            label: "alpha@example.com",
            emailLink: "mail.google.com/mail/u/0/#inbox",
            sortOrder: 0
        )
        try store.saveProfiles([profile])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubProfileViewDataService(),
            autoStart: false
        )
        let hostingView = makeHostingView(
            controller: controller,
            initialSessionExpanded: false
        )
        let window = hostInWindow(hostingView)
        defer {
            window.orderOut(nil)
        }

        flushViewHierarchy(for: hostingView)

        #expect(editableTextFieldCount(in: hostingView) == 2)
    }

    @Test
    func emailLinkOpenButtonPresentationUsesInlineFieldActionState() {
        let profileWithEmail = sampleProfile(
            label: "alpha@example.com",
            emailLink: "mail.google.com/mail/u/0/#inbox",
            sortOrder: 0
        )
        let profileWithoutEmail = sampleProfile(
            label: "beta@example.com",
            emailLink: nil,
            sortOrder: 1
        )

        let enabled = ProfileManagerEmailLinkButtonPresentation(profile: profileWithEmail)
        let disabled = ProfileManagerEmailLinkButtonPresentation(profile: profileWithoutEmail)

        #expect(enabled.title == "Open")
        #expect(enabled.symbolName == "arrow.up.forward.square")
        #expect(enabled.isDisabled == false)
        #expect(enabled.helpText == "Open email link")

        #expect(disabled.title == "Open")
        #expect(disabled.symbolName == "arrow.up.forward.square")
        #expect(disabled.isDisabled)
        #expect(disabled.helpText == "Add an email link before opening it.")
    }

    @Test
    func labelCopyButtonPresentationUsesStableInlineStates() {
        let normal = ProfileManagerLabelCopyButtonPresentation(
            labelDraft: "  alpha@example.com  ",
            isCopied: false
        )
        let copied = ProfileManagerLabelCopyButtonPresentation(
            labelDraft: "alpha@example.com",
            isCopied: true
        )
        let empty = ProfileManagerLabelCopyButtonPresentation(
            labelDraft: "   ",
            isCopied: false
        )

        #expect(normal.title == "Copy")
        #expect(normal.symbolName == "doc.on.doc")
        #expect(normal.isDisabled == false)
        #expect(normal.copyText == "alpha@example.com")

        #expect(copied.title == "Copied")
        #expect(copied.symbolName == "checkmark")
        #expect(copied.isDisabled == false)

        #expect(empty.title == "Copy")
        #expect(empty.symbolName == "doc.on.doc")
        #expect(empty.isDisabled)
        #expect(empty.copyText == "")
    }

    @Test
    func detailLayoutUsesCompactTopGridToExposeSessionBrowserSooner() {
        let metrics = ProfileManagerDetailLayoutMetrics.browserFirst

        #expect(metrics.detailStackSpacing < CodexTheme.contentSpacing)
        #expect(metrics.topGridSpacing < CodexTheme.contentSpacing)
        #expect(metrics.compactCardPadding < CodexTheme.panelPadding)
        #expect(metrics.actionPanelWidth <= 180)
        #expect(metrics.actionGridColumnCount == 3)
        #expect(metrics.sessionBrowserMinHeight >= 360)
    }

    @Test
    func tagFilterPresentationShowsFilteredCountForManagerSidebar() {
        let presentation = ProfileTagFilterBarPresentation(
            filter: ProfileTagFilter([.active]),
            shownCount: 2,
            totalCount: 5,
            tagCounts: ProfileTagCounts(active: 2, needAction: 1, pending: 2)
        )

        #expect(presentation.countText == "2 of 5 shown")
        #expect(presentation.visibleSummaryText == "2 of 5 shown")
        #expect(presentation.accessibilitySummaryText == "2 of 5 shown, 2 active, 1 need action, 2 pending")
        #expect(presentation.statusCountText == "2 active · 1 need action · 2 pending")
        #expect(presentation.isAllSelected == false)
        #expect(presentation.isSelected(.active))
        #expect(presentation.isSelected(.pending) == false)
    }

    @Test
    func expandedSessionPresentationKeepsHideSessionAction() {
        let snapshot = PlusProfileSnapshot(
            profile: sampleProfile(label: "alpha@example.com", sortOrder: 0),
            state: .ready,
            usage: nil,
            statusMessage: nil,
            isRefreshing: false
        )

        let expanded = ProfileManagerSessionPanelPresentation(
            snapshot: snapshot,
            isExpanded: true
        )
        let collapsed = ProfileManagerSessionPanelPresentation(
            snapshot: snapshot,
            isExpanded: false
        )

        #expect(expanded.toggleTitle == "Hide session")
        #expect(expanded.summaryText == "This profile session view is open.")
        #expect(collapsed.toggleTitle == "Show session")
    }
}

@MainActor
private final class StubProfileViewDataService: PlusProfileDataServing {
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        fatalError("Not used in ProfileManagerWindowViewTests")
    }

    func clearSession(for profile: PlusProfile) async throws {
    }

    func removeProfileData(for profile: PlusProfile) async throws {
    }

    func dataStore(for profile: PlusProfile) -> WKWebsiteDataStore {
        .nonPersistent()
    }
}

@MainActor
private func containsWebView(in rootView: NSView) -> Bool {
    rootView.allSubviews().contains(where: { $0 is WKWebView })
}

@MainActor
private func makeHostingView(
    controller: PlusProfileController,
    initialSessionExpanded: Bool
) -> NSHostingView<ProfileManagerWindowView> {
    let hostingView = NSHostingView(
        rootView: ProfileManagerWindowView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
            initialSessionExpanded: initialSessionExpanded
        )
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
    return hostingView
}

@MainActor
private func hostInWindow(_ hostingView: NSHostingView<ProfileManagerWindowView>) -> NSWindow {
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
private func flushViewHierarchy(for hostingView: NSHostingView<ProfileManagerWindowView>) {
    hostingView.layoutSubtreeIfNeeded()

    for _ in 0..<3 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
    }
}

private func sampleProfile(label: String, emailLink: String? = nil, sortOrder: Int) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: label,
        emailLink: emailLink,
        detectedNote: nil,
        tags: [],
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
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

@MainActor
private func editableTextFieldCount(in rootView: NSView) -> Int {
    rootView.allSubviews()
        .compactMap { $0 as? NSTextField }
        .filter(\.isEditable)
        .count
}
