import AppKit
import SwiftUI

@MainActor
final class ProfileManagerWindowPresenter {
    private let controller: PlusProfileController
    private let clock: AppMinuteClock
    private var window: NSWindow?

    init(controller: PlusProfileController, clock: AppMinuteClock) {
        self.controller = controller
        self.clock = clock
    }

    func show(selecting profileID: UUID? = nil) {
        if let profileID {
            controller.selectProfile(id: profileID)
        }

        let window = window ?? buildWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func buildWindow() -> NSWindow {
        let hostingView = NSHostingView(
            rootView: ProfileManagerWindowView(
                controller: controller,
                currentTime: clock
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "CodexPlusBar Profiles"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 720)
        window.center()
        return window
    }
}
