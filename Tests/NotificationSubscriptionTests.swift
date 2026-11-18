import Foundation
import Testing
@testable import CodexPlusBar

struct NotificationSubscriptionTests {
    @Test func receivesOnlyWhileItsOwnerRetainsTheSubscription() async {
        let name = Notification.Name(UUID().uuidString)
        await confirmation(expectedCount: 1) { received in
            withExtendedLifetime(NotificationSubscription(name) { received() }) {
                NotificationCenter.default.post(name: name, object: nil)
            }
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}
