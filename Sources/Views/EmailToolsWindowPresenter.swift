import AppKit
import SwiftUI

@MainActor
final class EmailToolsWindowPresenter {
    private let controller: DotTrickController
    private var window: NSWindow?

    init(controller: DotTrickController) {
        self.controller = controller
    }

    func show() {
        let window = window ?? buildWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func buildWindow() -> NSWindow {
        let hostingView = NSHostingView(
            rootView: EmailToolsWindowView(controller: controller)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Email Tools"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 560)
        window.center()
        return window
    }
}
