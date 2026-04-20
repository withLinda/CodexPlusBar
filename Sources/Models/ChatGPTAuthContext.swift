import Foundation

struct ChatGPTAuthContext: Equatable, Sendable {
    let accessToken: String
    let accountID: String
    let expiresAt: Date?
    let deviceID: String?
    let clientVersion: String?
    let language: String
}
