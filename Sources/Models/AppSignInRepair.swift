import Foundation

enum AppSignInDestination: String, Codable, CaseIterable, Sendable {
    case desktop, openChamber
    var title: String { self == .desktop ? "ChatGPT / Codex" : "OpenChamber" }
}

enum AppSignInRepairError: LocalizedError, Equatable {
    case helperUnavailable, helperFailed, invalidAuthorization, loginBusy, timedOut, denied
    case identityMismatch, sharedCredential, changed, storageFailed, interruptedInstallation
    var errorDescription: String? {
        switch self {
        case .helperUnavailable: "Install or update ChatGPT / Codex to repair app sign-ins."
        case .helperFailed: "The sign-in helper stopped. Try Repair both again."
        case .invalidAuthorization: "The sign-in helper returned an unsupported login response. Update ChatGPT / Codex and retry."
        case .loginBusy: "Another app is signing in. Finish that sign-in, then retry."
        case .timedOut: "Sign-in timed out. Try again when you are ready."
        case .denied: "Sign-in was not completed. Try again."
        case .identityMismatch: "That sign-in belongs to a different account or workspace. Retry with this profile’s account."
        case .sharedCredential: "The two apps received the same sign-in. Retry to create independent sign-ins."
        case .changed: "The account changed during repair. Its changes were kept; retry."
        case .storageFailed: "The repaired sign-in could not be saved. Check local storage and retry."
        case .interruptedInstallation: "The desktop sign-in changed after an interrupted repair. Sign in again to finish safely."
        }
    }
}

struct AppSignInRepairProgress: Equatable, Sendable {
    let profileID: UUID
    let destination: AppSignInDestination
    let message: String
}

struct AppSignInRepairCompletion: Sendable {
    let destination: AppSignInDestination
    let identity: CodexSignInIdentity
}

protocol AppSignInAuthorizing: Sendable {
    func authorize(profile: PlusProfile, openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> CodexSignIn
    func acknowledge(_ signIn: CodexSignIn, profile: PlusProfile) async throws
}

extension AppSignInAuthorizing {
    func acknowledge(_ signIn: CodexSignIn, profile: PlusProfile) async throws {}
}

protocol AppSignInRepairInstalling: Sendable {
    func install(_ signIn: CodexSignIn, for profile: PlusProfile, destination: AppSignInDestination) async throws
}

protocol AppSignInRepairing: Sendable {
    func repair(profile: PlusProfile, openURL: @escaping @Sendable (URL) async throws -> Void,
                progress: @escaping @Sendable (AppSignInRepairProgress) async -> Void,
                completed: @escaping @Sendable (AppSignInRepairCompletion) async throws -> Void,
                isCurrent: @escaping @Sendable () async -> Bool) async throws
}

extension CodexSignIn {
    func validateRepair(for profile: PlusProfile) throws {
        guard profile.provider == .codex else { throw AppSignInRepairError.identityMismatch }
        if let desktop = profile.codexSignIn, !desktop.matches(identity) { throw AppSignInRepairError.identityMismatch }
        if let openChamber = profile.openCodeOpenAIAccount,
           openChamber.accountID != identity.accountID || openChamber.userID != identity.userID {
            throw AppSignInRepairError.identityMismatch
        }
        if profile.codexSignIn == nil, profile.openCodeOpenAIAccount == nil,
           profile.label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(identity.email) != .orderedSame {
            throw AppSignInRepairError.identityMismatch
        }
    }

    func openChamberAuth() throws -> OpenCodeOpenAIAuth {
        guard let expiresAt else { throw CodexSignInError.invalidCredential }
        let milliseconds = expiresAt.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max) else { throw CodexSignInError.invalidCredential }
        return .init(type: "oauth", refresh: refreshToken, access: accessToken, expires: Int64(milliseconds), accountId: identity.accountID)
    }
}
