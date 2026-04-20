import Foundation

enum AuthState: String, Equatable, Sendable {
    case signedOut
    case signingIn
    case signedIn
    case noAccounts
    case expired
    case unsupported

    var needsSignIn: Bool {
        self == .signedOut || self == .expired
    }
}
