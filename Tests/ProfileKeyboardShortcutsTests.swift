import AppKit
import SwiftUI
import Testing
@testable import CodexPlusBar

@MainActor
struct ProfileKeyboardShortcutsTests {
    @Test
    func consecutiveNavigationDoesNotSaveThePreviousProfilesDraftIntoTheNextProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "KeyboardDraftTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = PlusProfileController(
            catalogStore: ProfileCatalogStore(fileURL: directory.appendingPathComponent("profiles.json")),
            autoStart: false
        )
        for label in ["first@example.com", "second@example.com", "third@example.com"] {
            controller.addProfile(label: label)
        }
        controller.selectProfile(id: controller.profiles.first?.id)
        let originals = controller.profiles.map(\.profile)
        let host = NSHostingView(rootView: ProfileManagerWindowView(
            controller: controller, currentTime: AppMinuteClock(), userDefaults: defaults
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer {
            window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bridge = try #require(descendants(host).compactMap { $0 as? ProfileKeyboardView }.first)
        #expect(bridge.handle?(.nextProfile) == true)
        #expect(bridge.handle?(.nextProfile) == true)
        #expect(controller.selectedProfileID == originals.last?.id)
        #expect(controller.profiles.map(\.profile) == originals)
    }

    @Test
    func mountedManagerRoutesNavigationAndZoomToItsOwnWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "KeyboardTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = PlusProfileController(
            catalogStore: ProfileCatalogStore(fileURL: directory.appendingPathComponent("profiles.json")),
            autoStart: false
        )
        controller.addProfile(label: "first@example.com")
        controller.addProfile(label: "second@example.com")
        controller.selectProfile(id: controller.profiles.first?.id)
        let host = NSHostingView(rootView: ProfileManagerWindowView(
            controller: controller, currentTime: AppMinuteClock(), userDefaults: defaults
        ))
        let window = KeyboardTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bridge = try #require(descendants(host).compactMap { $0 as? ProfileKeyboardView }.first)
        try #require(window.isKeyWindow)
        try #require(bridge.window === window)
        try #require(!bridge.isHiddenOrHasHiddenAncestor)
        try #require(window.attachedSheet == nil)
        try #require(NSApp.modalWindow == nil)
        try #require(bridge.handle != nil)
        func event(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = [], number: Int? = nil) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: number ?? window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        window.makeFirstResponder(nil)
        #expect(bridge.handleEvent(try event("\u{F701}", code: 125)))
        #expect(controller.selectedProfileID == controller.profiles.last?.id)
        #expect(bridge.handleEvent(try event("=", code: 24, flags: .command)))
        #expect(defaults.double(forKey: MenuBarPanelTextScalePreference.textScaleKey) == 1.1)
        #expect(!bridge.handleEvent(try event("-", code: 27, flags: .command, number: 0)))
        #expect(defaults.double(forKey: MenuBarPanelTextScalePreference.textScaleKey) == 1.1)
        window.simulatesKeyWindow = false
        #expect(!bridge.handleEvent(try event("-", code: 27, flags: .command)))
        #expect(defaults.double(forKey: MenuBarPanelTextScalePreference.textScaleKey) == 1.1)
        bridge.stopMonitoring()
    }

    @Test
    func acceptsPlusEqualsMinusAndReset() throws {
        for (characters, flags, expected) in [
            ("+", NSEvent.ModifierFlags.command, ProfileKeyboardAction.zoomIn),
            ("=", .command, .zoomIn),
            ("+", [.command, .shift], .zoomIn),
            ("-", .command, .zoomOut),
            ("0", .command, .resetZoom),
        ] {
            let event = try keyEvent(characters, flags: flags)
            #expect(ProfileKeyboardAction.resolve(event, firstResponder: nil) == expected)
        }
        #expect(ProfileKeyboardAction.resolve(try keyEvent("+", flags: []), firstResponder: nil) == nil)
        #expect(ProfileKeyboardAction.resolve(try keyEvent("=", flags: [.command, .option]), firstResponder: nil) == nil)
    }

    @Test
    func arrowsRespectEditorsAndModifiedKeys() throws {
        let down = try keyEvent("\u{F701}", code: 125)
        let up = try keyEvent("\u{F700}", code: 126)
        #expect(ProfileKeyboardAction.resolve(down, firstResponder: nil) == .nextProfile)
        #expect(ProfileKeyboardAction.resolve(up, firstResponder: nil) == .previousProfile)
        #expect(ProfileKeyboardAction.resolve(down, firstResponder: NSTextView()) == nil)
        #expect(ProfileKeyboardAction.resolve(up, firstResponder: NSComboBox()) == nil)
        #expect(ProfileKeyboardAction.resolve(try keyEvent("\u{F701}", flags: .shift, code: 125), firstResponder: nil) == nil)
        #expect(ProfileKeyboardAction.resolve(try keyEvent("=", flags: .command), firstResponder: NSTextView()) == .zoomIn)
    }
}

// Xcode's background test host cannot reliably become the foreground key app.
// Native preview QA covers real activation; this fixture controls the routing gate.
@MainActor
private final class KeyboardTestWindow: NSWindow {
    var simulatesKeyWindow = true
    override var isKeyWindow: Bool { simulatesKeyWindow }
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

private func keyEvent(_ characters: String, flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
    ))
}
