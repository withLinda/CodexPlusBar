import Foundation

/// Owns a block-based registration for as long as its subscriber needs it.
final class NotificationSubscription {
    private let token: NSObjectProtocol

    init(_ name: Notification.Name, queue: OperationQueue? = nil, onReceive: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: queue) { _ in
            onReceive()
        }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}
