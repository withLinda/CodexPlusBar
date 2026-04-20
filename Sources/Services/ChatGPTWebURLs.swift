import Foundation

enum ChatGPTWebURLs {
    static let codexPage = URL(string: "https://chatgpt.com/codex")!
    static let usagePage = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let loginPage = URL(string: "https://chatgpt.com/auth/login?next=%2Fcodex%2Fsettings%2Fusage")!
    static let cookieScope = URL(string: "https://chatgpt.com/")!
}
