import CryptoKit
import Foundation

/// Public identity only. Credentials never belong in the profile catalog.
struct CodexSignInIdentity: Codable, Equatable, Sendable {
    let accountID: String
    let userID: String
    let email: String

    var storageKey: String {
        SHA256.hash(data: Data("\(accountID)\n\(userID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ other: Self) -> Bool { accountID == other.accountID && userID == other.userID }
}

enum CodexSignInError: LocalizedError, Equatable {
    case missingCredential, missingSavedSignIn, invalidCredential, unsupportedCredential, identityMismatch
    case unsupportedConfiguration, configurationChanged, concurrentChange, storageFailed, keychainUnavailable
    case busy, appMissing, appCouldNotClose, reopenFailed
    case unauthorized, unavailable, invalidResponse, httpStatus(Int), rollbackFailed

    var errorDescription: String? {
        switch self {
        case .missingCredential: "Sign in to ChatGPT / Codex on this Mac, then save its current sign-in here."
        case .missingSavedSignIn: "Save this profile’s ChatGPT / Codex sign-in first."
        case .invalidCredential: "The desktop sign-in is incomplete. Sign in again in ChatGPT / Codex, then save it here."
        case .unsupportedCredential: "Use a ChatGPT account sign-in in the desktop app. API keys cannot be saved here."
        case .identityMismatch: "This sign-in belongs to a different account or workspace. Select its matching profile."
        case .unsupportedConfiguration: "This desktop authentication configuration is not supported. Use standard file or direct Keychain storage."
        case .configurationChanged: "The desktop authentication settings changed. Try again."
        case .concurrentChange: "Another app changed the desktop sign-in. Its changes were kept; try again when it finishes."
        case .storageFailed: "Could not save the desktop sign-in. Check access to its credential storage."
        case .keychainUnavailable: "The desktop sign-in’s Keychain item could not be accessed. Allow access in macOS, then try again."
        case .busy: "Another desktop sign-in action is still running."
        case .appMissing: "Install the ChatGPT / Codex desktop app before switching."
        case .appCouldNotClose: "ChatGPT / Codex could not close. Finish its current work, quit it, then try again."
        case .reopenFailed: "ChatGPT / Codex could not reopen. Open the desktop app manually."
        case .unauthorized: "This saved sign-in has expired or was rejected. Sign in again in ChatGPT / Codex, then save it here."
        case .unavailable: "OpenAI could not be reached. Check your connection and try again."
        case .invalidResponse: "OpenAI returned an unreadable sign-in response. Try again later."
        case .httpStatus(let code): "OpenAI sign-in verification returned HTTP \(code). Try again later."
        case .rollbackFailed: "The previous desktop sign-in could not be restored. Check the account in ChatGPT / Codex."
        }
    }
}

/// Retains the complete source document, including fields added by newer Codex versions.
struct CodexSignIn: Equatable, Sendable {
    let data: Data
    let identity: CodexSignInIdentity
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date?

    init(data: Data) throws {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexSignInError.invalidCredential
        }
        guard object["auth_mode"] == nil || object["auth_mode"] as? String == "chatgpt",
              (object["OPENAI_API_KEY"] as? String)?.isEmpty != false else {
            throw CodexSignInError.unsupportedCredential
        }
        guard let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw CodexSignInError.invalidCredential
        }
        let idClaims = try Self.claims(idToken)
        let accessClaims = try Self.claims(access)
        let id = try Self.identity(idClaims, fallbackEmail: nil)
        let accessIdentity = try Self.identity(accessClaims, fallbackEmail: id.email)
        guard id.matches(accessIdentity),
              tokens["account_id"] as? String == nil || tokens["account_id"] as? String == id.accountID else {
            throw CodexSignInError.invalidCredential
        }
        self.data = data
        identity = id
        accessToken = access
        refreshToken = refresh
        expiresAt = (accessClaims["exp"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
    }

    func needsRefresh(at date: Date) -> Bool {
        expiresAt.map { $0 <= date.addingTimeInterval(30) } ?? false
    }

    func replacingTokens(access: String, refresh: String?, idToken: String?, at date: Date) throws -> Self {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = object["tokens"] as? [String: Any] else { throw CodexSignInError.invalidCredential }
        tokens["access_token"] = access
        if let refresh { tokens["refresh_token"] = refresh }
        if let idToken { tokens["id_token"] = idToken }
        object["tokens"] = tokens
        object["last_refresh"] = ISO8601DateFormatter().string(from: date)
        let updated = try Self(data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        guard identity.matches(updated.identity) else { throw CodexSignInError.identityMismatch }
        return updated
    }

    func validate(for profile: PlusProfile) throws {
        guard profile.provider == .codex else { throw CodexSignInError.identityMismatch }
        if let saved = profile.codexSignIn {
            guard saved.matches(identity) else { throw CodexSignInError.identityMismatch }
        } else if let saved = profile.openCodeOpenAIAccount {
            guard saved.accountID == identity.accountID, saved.userID == identity.userID else {
                throw CodexSignInError.identityMismatch
            }
        } else {
            guard profile.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == identity.email.lowercased() else {
                throw CodexSignInError.identityMismatch
            }
        }
    }

    private static func claims(_ jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { throw CodexSignInError.invalidCredential }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
            throw CodexSignInError.invalidCredential
        }
        return claims
    }

    private static func identity(_ claims: [String: Any], fallbackEmail: String?) throws -> CodexSignInIdentity {
        guard let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = auth["chatgpt_account_id"] as? String, !account.isEmpty,
              let user = (auth["chatgpt_user_id"] ?? auth["user_id"]) as? String, !user.isEmpty,
              let email = (claims["email"] as? String)
                ?? (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
                ?? fallbackEmail, !email.isEmpty else { throw CodexSignInError.invalidCredential }
        // Claim consistency is local validation; live verification establishes acceptance.
        guard auth["chatgpt_account_is_fedramp"] as? Bool != true else { throw CodexSignInError.unsupportedConfiguration }
        return CodexSignInIdentity(accountID: account, userID: user, email: email)
    }
}
