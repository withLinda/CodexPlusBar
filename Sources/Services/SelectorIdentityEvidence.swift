import CoreFoundation
import Foundation

/// Consistency checks on authenticated browser evidence, not JWT signature verification.
/// Saved identities, labels, email and JWT `sub` never supply missing browser evidence.
enum SelectorIdentityEvidence {
    static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func userID(sessionIDs: [String?], token: String) -> String? {
        let auth = claims(token)["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let values = sessionIDs + [auth["chatgpt_user_id"] as? String, auth["user_id"] as? String]
        let ids = Set(values.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return ids.count == 1 ? ids.first : nil
    }

    static func matches(context: ChatGPTAuthContext, accountID: String?, native: OpenCodeOpenAIIdentity,
                        catalog: [AccountCatalogItem]?) -> Bool {
        guard !native.accountID.isEmpty, !native.userID.isEmpty,
              context.userID == native.userID, let accountID else { return false }
        let auth = claims(context.accessToken)["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard userID(sessionIDs: [context.userID], token: context.accessToken) == native.userID else { return false }
        let ids = [context.accountID, accountID] + [auth["chatgpt_account_id"] as? String].compactMap { $0 }
        return ids.allSatisfy { id in
            if id == native.accountID { return true }
            let matches = catalog?.filter { $0.matchesAccountID(id) } ?? []
            return matches.count == 1 && matches[0].accountID == native.accountID
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded() == raw, abs(raw) <= 9_007_199_254_740_991 else { return nil }
        return Int(raw)
    }
}
