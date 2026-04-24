import Foundation

enum AccountCatalogNormalizer {
    static func normalize(_ items: [AccountCatalogItem]) -> [AccountCatalogItem] {
        var groupedItems: [String: [AccountCatalogItem]] = [:]
        var orderedAccountIDs: [String] = []

        for item in items {
            if groupedItems[item.accountID] == nil {
                orderedAccountIDs.append(item.accountID)
            }
            groupedItems[item.accountID, default: []].append(item)
        }

        return orderedAccountIDs.compactMap { accountID in
            guard let duplicates = groupedItems[accountID] else {
                return nil
            }
            return merge(duplicates)
        }
    }

    private static func merge(_ items: [AccountCatalogItem]) -> AccountCatalogItem {
        precondition(items.isEmpty == false)

        var baseItem = items[0]
        var bestScore = descriptiveScore(for: baseItem)

        for item in items.dropFirst() {
            let score = descriptiveScore(for: item)
            if score > bestScore {
                baseItem = item
                bestScore = score
            }
        }

        let hasActiveSubscription: Bool?
        if items.contains(where: { $0.hasActiveSubscription == false }) {
            hasActiveSubscription = false
        } else if items.contains(where: { $0.hasActiveSubscription == true }) {
            hasActiveSubscription = true
        } else {
            hasActiveSubscription = nil
        }

        return AccountCatalogItem(
            accountID: baseItem.accountID,
            displayName: baseItem.displayName,
            planType: baseItem.planType,
            expiresAt: items.compactMap(\.expiresAt).min(),
            renewsAt: items.compactMap(\.renewsAt).min(),
            hasActiveSubscription: hasActiveSubscription,
            isDeactivated: items.contains(where: { $0.isDeactivated }),
            isUsableInSession: items.allSatisfy { $0.isUsableInSession },
            matchAliases: Set(items.flatMap(\.matchAliases)),
            isDefaultAccount: items.contains(where: { $0.isDefaultAccount })
        )
    }

    private static func descriptiveScore(for item: AccountCatalogItem) -> Int {
        var score = 0

        if item.displayName != item.accountID {
            score += 4
        }
        if item.planType != "unknown" {
            score += 2
        }
        if item.expiresAt != nil {
            score += 1
        }
        if item.renewsAt != nil {
            score += 1
        }
        if item.hasActiveSubscription != nil {
            score += 1
        }

        return score
    }
}
