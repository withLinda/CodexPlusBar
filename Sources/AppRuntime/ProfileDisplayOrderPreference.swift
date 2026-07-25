import Foundation

enum ProfileDisplayOrderPreference {
    static let orderKey = "ProfileDisplayOrder"
    static let defaultOrder = ProfileDisplayOrder.defaultOrder

    static func order(defaults: UserDefaults = .standard) -> ProfileDisplayOrder {
        guard let rawValue = defaults.string(forKey: orderKey),
              let order = ProfileDisplayOrder(rawValue: rawValue) else {
            return defaultOrder
        }

        return order
    }

    static func setOrder(
        _ order: ProfileDisplayOrder,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(order.rawValue, forKey: orderKey)
    }
}
