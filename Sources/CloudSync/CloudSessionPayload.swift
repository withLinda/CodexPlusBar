import Foundation

enum CloudSessionError: Error, Equatable, Sendable {
    case invalidPayload, identityMismatch, unavailable, consumedGeneration
}

/// Account/user IDs come from credential claims or an authenticated browser session.
/// Display labels, email, catalog observations and native connection IDs are not proof.
struct CloudSessionIdentity: Codable, Equatable, Sendable {
    let accountID: String
    let userID: String

    func validate() throws {
        guard [accountID, userID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\n") }) else {
            throw CloudSessionError.identityMismatch
        }
    }

    func validateBindings(of profile: PlusProfile) throws {
        try validate()
        if let identity = profile.codexSignIn {
            guard identity.accountID == accountID, identity.userID == userID else { throw CloudSessionError.identityMismatch }
        }
        if let identity = profile.openCodeOpenAIAccount {
            guard identity.accountID == accountID, identity.userID == userID else { throw CloudSessionError.identityMismatch }
        }
    }
}

extension CodexSignIn: Codable {
    init(from decoder: any Decoder) throws { try self.init(data: decoder.singleValueContainer().decode(Data.self)) }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        // Object ordering is not a credential generation change.
        let object = try JSONSerialization.jsonObject(with: data)
        try container.encode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}

enum CloudSessionPayload: Codable, Equatable, Sendable {
    case browser(cookies: [BackupCookie], identity: CloudSessionIdentity, accessToken: String)
    case desktop(signIn: CodexSignIn, consumed: [String])
    case openChamber(value: OpenCodeCredentialValue, consumed: [String])

    var kind: CloudSessionKind {
        switch self { case .browser: .browser; case .desktop: .desktop; case .openChamber: .openChamber }
    }

    var identity: CloudSessionIdentity {
        get throws {
            switch self {
            case .browser(_, let identity, _): return identity
            case .desktop(let signIn, _): return .init(accountID: signIn.identity.accountID, userID: signIn.identity.userID)
            case .openChamber(let value, _):
                let identity = try value.auth().identity()
                return .init(accountID: identity.accountID, userID: identity.userID)
            }
        }
    }

    var consumed: Set<String> {
        switch self { case .browser: []; case .desktop(_, let values), .openChamber(_, let values): Set(values) }
    }

    var generationFingerprint: String? {
        get throws {
            switch self {
            case .browser: return nil
            case .desktop(let signIn, _): return Self.fingerprint(signIn.refreshToken)
            case .openChamber(let value, _):
                let auth = try value.auth()
                return Self.fingerprint("\(auth.access)\n\(auth.refresh)\n\(auth.expires)")
            }
        }
    }

    static func fingerprint(_ value: String) -> String {
        CloudJournalCoding.digest(Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Revalidates decoded credentials, canonicalizes sets, and rejects installation metadata.
    func validated() throws -> Self {
        try identity.validate()
        guard consumed.count <= 10_000, consumed.allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw CloudSessionError.invalidPayload
        }
        if let fingerprint = try generationFingerprint, consumed.contains(fingerprint) { throw CloudSessionError.consumedGeneration }
        switch self {
        case .desktop(let signIn, _):
            return .desktop(signIn: try CodexSignIn(data: signIn.data), consumed: consumed.sorted())
        case .openChamber(let value, _):
            let auth = try value.auth()
            var portable = OpenCodeCredentialValue.legacy(auth)
            portable.fields["methodID"] = value.fields["methodID"]
            guard portable == value else { throw CloudSessionError.invalidPayload }
            return .openChamber(value: portable, consumed: consumed.sorted())
        case .browser(let cookies, let identity, let token):
            let auth = SelectorIdentityEvidence.claims(token)["https://api.openai.com/auth"] as? [String: Any]
            guard token.utf8.count <= 1_048_576, auth?["chatgpt_account_id"] as? String == identity.accountID,
                  SelectorIdentityEvidence.userID(sessionIDs: [], token: token) == identity.userID,
                  !cookies.isEmpty, cookies.count <= 10_000, cookies.allSatisfy({ $0.isValid(for: .codex) }),
                  cookies.contains(where: { cookie in
                      let name = cookie.name, prefix = "__Secure-next-auth.session-token."
                      if name == "__Secure-next-auth.session-token" { return true }
                      let suffix = name.dropFirst(prefix.count)
                      return name.hasPrefix(prefix) && !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
                  }),
                  Set(cookies.map { "\($0.domain)\n\($0.path)\n\($0.name)" }).count == cookies.count else { throw CloudSessionError.invalidPayload }
            let ordered = try cookies.map { (cookie: $0, bytes: try CloudJournalCoding.encode($0)) }
                .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }.map(\.cookie)
            return .browser(cookies: ordered, identity: identity, accessToken: token)
        }
    }

    func encoded() throws -> Data { try CloudJournalCoding.encode(validated()) }
    func digest() throws -> Data { try CloudJournalCoding.digest(encoded()) }
}
