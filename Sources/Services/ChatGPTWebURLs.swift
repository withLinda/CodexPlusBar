import Foundation

enum ChatGPTWebURLs {
    static let codexPage = URL(string: "https://chatgpt.com/codex")!
    static let usagePage = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
    static let loginPage = URL(string: "https://chatgpt.com/auth/login?next=%2Fcodex%2Fcloud%2Fsettings%2Fanalytics%23usage")!
    static let cookieScope = URL(string: "https://chatgpt.com/")!
    static let passkeySetupPage = URL(string: "chrome://password-manager/settings")!
}

enum ClaudeWebURLs {
    static let organizationID = "37255346-bbc8-48a0-9d5e-a3e3329a3d80"
    static let loginPage = URL(string: "https://claude.ai/login")!
    static let usagePage = URL(string: "https://claude.ai/settings/usage")!
    static let cookieScope = URL(string: "https://claude.ai/")!
    static let usageEndpoint = URL(
        string: "https://claude.ai/api/organizations/\(organizationID)/usage"
    )!
}

enum ChromeBrowserSignInURLs {
    static let googleAccountEmail = "linda.fitriani@gmail.com"

    static var googleSyncSignInPage: URL {
        googleSyncSignInPage(
            email: googleAccountEmail
        )
    }

    static func googleSyncSignInPage(email: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.google.com"
        components.path = "/signin/v2/identifier"
        components.queryItems = [
            URLQueryItem(name: "service", value: "chromiumsync"),
            URLQueryItem(name: "login_hint", value: email),
            URLQueryItem(name: "flowName", value: "GlifWebSignIn"),
            URLQueryItem(name: "flowEntry", value: "ServiceLogin"),
        ]

        return components.url!
    }
}
