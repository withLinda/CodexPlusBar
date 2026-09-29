import Foundation

struct CodexSavedAccount: Decodable, Sendable {
    let accountKey: String
    let chatgptAccountID: String
    let chatgptUserID: String
    let email: String

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptUserID = "chatgpt_user_id"
        case email
    }
}

struct CodexSavedAccountRegistry: Decodable, Sendable {
    let accounts: [CodexSavedAccount]
}

/// Read-only compatibility with existing saved accounts; never invokes or updates the old helper.
struct CodexLegacySignInImporter {
    let homeDirectory: URL
    private var directory: URL { homeDirectory.appendingPathComponent(".codex/accounts") }

    func linkedAccount(for profile: PlusProfile) throws -> CodexSavedAccount {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("registry.json")),
              let registry = try? JSONDecoder().decode(CodexSavedAccountRegistry.self, from: data) else {
            throw CodexSignInError.missingSavedSignIn
        }
        let matches = registry.accounts.filter {
            if let key = profile.codexAccountKey { return $0.accountKey == key }
            return $0.email.lowercased() == profile.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard matches.count == 1, let account = matches.first else { throw CodexSignInError.identityMismatch }
        return account
    }

    func migrate(_ profiles: [PlusProfile]) -> ([PlusProfile], changed: Bool) {
        let vault = CodexSignInVault(homeDirectory: homeDirectory)
        var changed = false
        let result = profiles.map { profile -> PlusProfile in
            guard profile.provider == .codex, profile.codexSignIn == nil,
                  let account = try? linkedAccount(for: profile),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(account.accountKey) + ".auth.json")),
                  let signIn = try? CodexSignIn(data: data),
                  signIn.identity.accountID == account.chatgptAccountID,
                  signIn.identity.userID == account.chatgptUserID else { return profile }
            if let linked = profile.openCodeOpenAIAccount,
               linked.accountID != signIn.identity.accountID || linked.userID != signIn.identity.userID { return profile }
            do {
                // A previous import may already have rotated. Never overwrite that newer snapshot.
                if !FileManager.default.fileExists(atPath: vault.url(for: signIn.identity).path) {
                    try vault.save(signIn)
                }
                _ = try vault.load(signIn.identity)
                var updated = profile
                updated.codexSignIn = signIn.identity
                changed = true
                return updated
            } catch { return profile }
        }
        return (result, changed)
    }

    private static func fileName(_ key: String) -> String {
        let valid = key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }
        if valid, !key.isEmpty, key != ".", key != ".." { return key }
        return Data(key.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
