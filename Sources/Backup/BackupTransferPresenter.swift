import AppKit
import SwiftUI

@MainActor final class BackupTransferPresenter: NSObject, NSWindowDelegate {
    let controller: BackupTransferController
    private var window: NSWindow?

    init(controller: BackupTransferController) { self.controller = controller }

    func show(_ mode: BackupTransferMode) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Backup & Transfer"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BackupTransferView(controller: controller))
            window.delegate = self
            window.center()
            self.window = window
            controller.window = window
            controller.dismiss = { [weak self] in self?.window?.orderOut(nil) }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.begin(mode)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !controller.isBusy else { return false }
        controller.cancel()
        return true
    }
}
