import Foundation

struct ChatGPTAuthContext: Equatable, Sendable {
    let accessToken: String
    let accountID: String
    let expiresAt: Date?
    let deviceID: String?
    let clientVersion: String?
    let language: String
    let userID: String?

    init(accessToken: String, accountID: String, expiresAt: Date?, deviceID: String?,
         clientVersion: String?, language: String, userID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
        self.deviceID = deviceID
        self.clientVersion = clientVersion
        self.language = language
        self.userID = userID
    }
}
