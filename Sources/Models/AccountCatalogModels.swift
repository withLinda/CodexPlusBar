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
    let matchAliases: Set<String>
    let isDefaultAccount: Bool

    var id: String {
        accountID
    }

    func matchesAccountID(_ accountID: String) -> Bool {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false && matchAliases.contains(trimmed)
    }
}
