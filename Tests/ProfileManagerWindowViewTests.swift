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
