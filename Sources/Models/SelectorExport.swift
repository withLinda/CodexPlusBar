import Foundation

/// This protocol intentionally contains no general profile or credential object.
struct SelectorExport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourceInstanceID: String
    let sequence: Int64
    let generatedAtMs: Int64
    let catalogTrusted: Bool
    let accounts: [Account]

    struct Window: Codable, Equatable, Sendable {
        let remainingPercent: Int
        let resetAtMs: Int64
    }
    struct SevenDay: Codable, Equatable, Sendable {
        let state: String
        let remainingPercent: Int?
        let resetAtMs: Int64?
    }
    struct Usage: Codable, Equatable, Sendable {
        let observedAtMs: Int64
        let identityKey: String
        let allowed: Bool
        let limitReached: Bool
        let fiveHour: Window
        let sevenDay: SevenDay
    }
    struct Entitlement: Codable, Equatable, Sendable {
        let observedAtMs: Int64
        let accountID: String
        let expiresAtMs: Int64?
        let active: Bool?
        let deactivated: Bool
        let usable: Bool
        let match: String

        enum CodingKeys: String, CodingKey { case observedAtMs, accountID, expiresAtMs, active, deactivated, usable, match }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(observedAtMs, forKey: .observedAtMs)
            try values.encode(accountID, forKey: .accountID)
            try values.encode(expiresAtMs, forKey: .expiresAtMs)
            try values.encode(active, forKey: .active)
            try values.encode(deactivated, forKey: .deactivated)
            try values.encode(usable, forKey: .usable)
            try values.encode(match, forKey: .match)
        }
    }
    struct Account: Codable, Equatable, Sendable {
        let profileID: String
        let credentialID: String
        let identityKey: String
        let accountID: String
        let label: String
        let bindingObservedAtMs: Int64
        let usage: Usage?
        let entitlement: Entitlement?
        let unavailableReasons: [String]

        enum CodingKeys: String, CodingKey { case profileID, credentialID, identityKey, accountID, label, bindingObservedAtMs, usage, entitlement, unavailableReasons }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(profileID, forKey: .profileID)
            try values.encode(credentialID, forKey: .credentialID)
            try values.encode(identityKey, forKey: .identityKey)
            try values.encode(accountID, forKey: .accountID)
            try values.encode(label, forKey: .label)
            try values.encode(bindingObservedAtMs, forKey: .bindingObservedAtMs)
            try values.encode(usage, forKey: .usage)
            try values.encode(entitlement, forKey: .entitlement)
            try values.encode(unavailableReasons, forKey: .unavailableReasons)
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw CocoaError(.coderInvalidValue) }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1, result.accounts.count <= 256,
              UUID(uuidString: result.sourceInstanceID) != nil,
              result.sequence >= 0, result.sequence <= 9_007_199_254_740_991 else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991 else { throw CocoaError(.coderInvalidValue) }
        return Int64(value)
    }

    static func account(profile: PlusProfile, credentialID: String, bindingObservedAt: Date,
                        observation: SelectorObservation?) throws -> Account? {
        guard let identity = profile.openCodeOpenAIAccount, !credentialID.isEmpty else { return nil }
        let evidence = observation?.identityKey == identity.storageKey ? observation : nil
        var usage: Usage?
        if let observed = evidence?.usage, observed.sevenDay != .unknown {
            let weekly: SevenDay
            switch observed.sevenDay {
            case let .available(window): weekly = SevenDay(state: "available", remainingPercent: window.remainingPercent, resetAtMs: try milliseconds(window.resetAt))
            case .notApplicable: weekly = SevenDay(state: "not-applicable", remainingPercent: nil, resetAtMs: nil)
            case .unknown: throw CocoaError(.coderInvalidValue)
            }
            usage = Usage(observedAtMs: try milliseconds(observed.observedAt), identityKey: observed.identityKey,
                allowed: observed.allowed, limitReached: observed.limitReached,
                fiveHour: Window(remainingPercent: observed.fiveHour.remainingPercent, resetAtMs: try milliseconds(observed.fiveHour.resetAt)), sevenDay: weekly)
        }
        let entitlement = try evidence?.entitlement.map { observed in
            Entitlement(observedAtMs: try milliseconds(observed.observedAt), accountID: observed.accountID,
                expiresAtMs: try observed.expiresAt.map(milliseconds), active: observed.active,
                deactivated: observed.deactivated, usable: observed.usable, match: observed.match.rawValue)
        }
        return Account(profileID: profile.id.uuidString, credentialID: credentialID, identityKey: identity.storageKey,
            accountID: identity.accountID, label: String(profile.displayLabel.unicodeScalars.prefix(200)), bindingObservedAtMs: try milliseconds(bindingObservedAt),
            usage: usage, entitlement: entitlement, unavailableReasons: evidence?.unavailableReasons ?? ["usage-unknown", "expiry-unknown"])
    }
}
