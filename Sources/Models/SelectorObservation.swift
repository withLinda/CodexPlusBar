import Foundation

struct SelectorQuotaWindow: Equatable, Sendable {
    let remainingPercent: Int
    let resetAt: Date
}

enum SelectorSevenDay: Equatable, Sendable {
    case unknown
    case notApplicable
    case available(SelectorQuotaWindow)
}

struct SelectorUsageObservation: Equatable, Sendable {
    let observedAt: Date
    let identityKey: String
    let allowed: Bool
    let limitReached: Bool
    let fiveHour: SelectorQuotaWindow
    let sevenDay: SelectorSevenDay
}

struct SelectorUsageEvidence: Equatable, Sendable {
    let accountID: String?
    let allowed: Bool?
    let limitReached: Bool?
    let fiveHour: SelectorQuotaWindow?
    let sevenDay: SelectorSevenDay
}

struct SelectorCatalogEvidence: Equatable, Sendable {
    let deactivated: Bool?
    let usable: Bool?
    let active: Bool?
    let valid: Bool
}

struct SelectorEntitlementObservation: Equatable, Sendable {
    enum Match: String, Sendable { case canonical; case uniqueAlias = "unique-alias" }
    let observedAt: Date
    let accountID: String
    let expiresAt: Date?
    let active: Bool?
    let deactivated: Bool
    let usable: Bool
    let match: Match
}

struct SelectorObservation: Equatable, Sendable {
    let identityKey: String
    let accountID: String
    let usage: SelectorUsageObservation?
    let entitlement: SelectorEntitlementObservation?
    let unavailableReasons: [String]

    static func make(context: ChatGPTAuthContext, snapshot: WorkspaceLimitSnapshot,
                     catalog: [AccountCatalogItem]?, entitlementObservedAt: Date?,
                     nativeIdentity: OpenCodeOpenAIIdentity?) -> Self? {
        guard let nativeIdentity else { return nil }
        guard SelectorIdentityEvidence.matches(context: context, accountID: snapshot.selectorEvidence?.accountID,
                                               native: nativeIdentity, catalog: catalog) else {
            return Self(identityKey: nativeIdentity.storageKey, accountID: nativeIdentity.accountID,
                        usage: nil, entitlement: nil, unavailableReasons: ["identity-mismatch"])
        }
        var reasons: [String] = []
        var usage: SelectorUsageObservation?
        if let raw = snapshot.selectorEvidence, let allowed = raw.allowed, let reached = raw.limitReached,
           let window = raw.fiveHour, raw.sevenDay != .unknown {
            usage = SelectorUsageObservation(observedAt: snapshot.fetchedAt, identityKey: nativeIdentity.storageKey,
                allowed: allowed, limitReached: reached, fiveHour: window, sevenDay: raw.sevenDay)
        } else {
            reasons.append("usage-unknown")
        }
        var entitlement: SelectorEntitlementObservation?
        if let catalog, let entitlementObservedAt {
            // Only exact canonical/default mirrors are collapsed by the decoder;
            // display normalization must never hide conflicting evidence.
            let matches = catalog.filter { $0.accountID == nativeIdentity.accountID }
            if matches.count == 1, let item = matches.first, let raw = item.selectorEvidence,
               raw.valid, let deactivated = raw.deactivated, let usable = raw.usable {
                entitlement = SelectorEntitlementObservation(observedAt: entitlementObservedAt,
                    accountID: nativeIdentity.accountID, expiresAt: item.expiresAt, active: raw.active,
                    deactivated: deactivated, usable: usable,
                    match: context.accountID == nativeIdentity.accountID && snapshot.accountID == nativeIdentity.accountID
                        ? .canonical : .uniqueAlias)
            } else {
                reasons.append("expiry-unknown")
            }
        } else {
            reasons.append("expiry-refresh-failed")
        }
        return Self(identityKey: nativeIdentity.storageKey, accountID: nativeIdentity.accountID,
                    usage: usage, entitlement: entitlement, unavailableReasons: reasons)
    }
}
