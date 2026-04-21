import Foundation

struct AccountCatalogItem: Identifiable, Equatable, Sendable {
    let accountID: String
    let displayName: String
    let planType: String
    let expiresAt: Date?
    let renewsAt: Date?
    let hasActiveSubscription: Bool?
    let isDeactivated: Bool
    let isUsableInSession: Bool

    var id: String {
        accountID
    }
}
