import Foundation

enum ChatGPTWebURLs {
    static let codexPage = URL(string: "https://chatgpt.com/codex")!
    static let usagePage = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
    static let loginPage = URL(string: "https://chatgpt.com/auth/login?next=%2Fcodex%2Fcloud%2Fsettings%2Fanalytics%23usage")!
    static let cookieScope = URL(string: "https://chatgpt.com/")!
    static let passkeySetupPage = URL(string: "chrome://password-manager/settings")!
}
