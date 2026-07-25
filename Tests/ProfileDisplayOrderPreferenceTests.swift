import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileDisplayOrderPreferenceTests {
    @Test
    func missingOrUnknownPreferenceUsesNextResetOrder() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(ProfileDisplayOrderPreference.order(defaults: defaults) == .nextReset)

        defaults.set("unsupported-order", forKey: ProfileDisplayOrderPreference.orderKey)

        #expect(ProfileDisplayOrderPreference.order(defaults: defaults) == .nextReset)
    }

    @Test(arguments: ProfileDisplayOrder.allCases)
    func selectedOrderRoundTripsThroughUserDefaults(_ order: ProfileDisplayOrder) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        ProfileDisplayOrderPreference.setOrder(order, defaults: defaults)

        #expect(ProfileDisplayOrderPreference.order(defaults: defaults) == order)
    }
}

private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "ProfileDisplayOrderPreferenceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
