import AppKit
import Foundation

final class CodexAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: CodexAppNotifications.reopenAccountWindowLocally, object: nil)
        return false
    }
}
