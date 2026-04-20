import SwiftUI
import WebKit

struct ProfileSignInWebView: NSViewRepresentable {
    let dataStore: WKWebsiteDataStore
    let initialURL: URL

    init(
        dataStore: WKWebsiteDataStore,
        initialURL: URL = ChatGPTWebURLs.loginPage
    ) {
        self.dataStore = dataStore
        self.initialURL = initialURL
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
    }
}
