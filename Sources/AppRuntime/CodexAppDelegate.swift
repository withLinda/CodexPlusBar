import AppKit
import Foundation
import CloudKit

enum CodexCloudNotifications {
    static let received = Notification.Name("CodexPlusBar.cloudNotification")
    static let registered = Notification.Name("CodexPlusBar.cloudRegistered")
    static let registrationFailed = Notification.Name("CodexPlusBar.cloudRegistrationFailed")
    static let accountChanged = Notification.Name.CKAccountChanged
}

@MainActor enum CodexCloudLifecycle {
    static var shutdown: (@MainActor () async -> Void)?
}

final class CodexAppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown = CodexCloudLifecycle.shutdown else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: CodexCloudNotifications.registered, object: nil)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationCenter.default.post(name: CodexCloudNotifications.registrationFailed, object: nil)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        NotificationCenter.default.post(name: CodexCloudNotifications.received, object: nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: CodexAppNotifications.reopenAccountWindowLocally, object: nil)
        return false
    }
}
