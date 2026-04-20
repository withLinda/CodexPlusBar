import Foundation

struct ChatGPTRequestSigner {
    private static let jsonAcceptValue = "application/json, text/plain, */*"
    private static let browserAcceptValue = "*/*"

    private enum RequestKind {
        case backendAPI
        case workspaceSwitch
        case currentSession
        case other
    }

    static func sign(
        _ request: URLRequest,
        cookies: [HTTPCookie],
        authContext: ChatGPTAuthContext?
    ) -> URLRequest {
        var signedRequest = request
        signedRequest.httpShouldHandleCookies = false
        let requestKind = requestKind(for: signedRequest.url)

        applyBrowserScaffoldHeaders(to: &signedRequest, requestKind: requestKind)
        if shouldIncludeOriginHeader(for: requestKind) {
            signedRequest.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        } else {
            signedRequest.setValue(nil, forHTTPHeaderField: "Origin")
        }
        signedRequest.setValue(refererValue(for: signedRequest.url), forHTTPHeaderField: "Referer")

        if requestKind == .backendAPI,
           let language = authContext?.language,
           language.isEmpty == false {
            signedRequest.setValue(language, forHTTPHeaderField: "OAI-Language")
        }

        HTTPCookie.requestHeaderFields(with: cookies).forEach { key, value in
            signedRequest.setValue(value, forHTTPHeaderField: key)
        }

        guard let authContext else {
            return signedRequest
        }

        if requestKind == .backendAPI || requestKind == .workspaceSwitch,
           let deviceID = authContext.deviceID,
           deviceID.isEmpty == false {
            signedRequest.setValue(deviceID, forHTTPHeaderField: "OAI-Device-Id")
        }

        if requestKind == .backendAPI || requestKind == .workspaceSwitch,
           let clientVersion = authContext.clientVersion,
           clientVersion.isEmpty == false {
            signedRequest.setValue(clientVersion, forHTTPHeaderField: "OAI-Client-Version")
        }

        guard requestKind == .backendAPI else {
            return signedRequest
        }

        signedRequest.setValue("Bearer \(authContext.accessToken)", forHTTPHeaderField: "Authorization")

        let accountID = signedRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") ?? authContext.accountID
        signedRequest.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")

        return signedRequest
    }

    static func shouldUseJSONAccept(for url: URL?) -> Bool {
        guard let url else {
            return false
        }

        if url.path.hasPrefix("/backend-api/") {
            return true
        }

        return url.path == "/api/auth/session"
    }

    static func shouldApplyAuthHeaders(to request: URLRequest) -> Bool {
        requestKind(for: request.url) == .backendAPI
    }

    private static func workspaceSwitchTargetID(from url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "exchange_workspace_token" && $0.value == "true" }) == true
        else {
            return nil
        }

        return components.queryItems?.first(where: { $0.name == "workspace_id" })?.value
    }

    private static func requestKind(for url: URL?) -> RequestKind {
        guard let url else {
            return .other
        }

        if workspaceSwitchTargetID(from: url) != nil {
            return .workspaceSwitch
        }

        if url.path.hasPrefix("/backend-api/") {
            return .backendAPI
        }

        if url.path == "/api/auth/session" {
            return .currentSession
        }

        return .other
    }

    private static func applyBrowserScaffoldHeaders(to request: inout URLRequest, requestKind: RequestKind) {
        guard let url = request.url else {
            return
        }

        if requestKind == .workspaceSwitch {
            request.setValue(browserAcceptValue, forHTTPHeaderField: "Accept")
            request.setValue("/api/auth/session", forHTTPHeaderField: "X-OpenAI-Target-Path")
            request.setValue("/api/auth/session", forHTTPHeaderField: "X-OpenAI-Target-Route")
            return
        }

        if url.path.hasPrefix("/backend-api/wham/") {
            request.setValue(browserAcceptValue, forHTTPHeaderField: "Accept")
            request.setValue(url.path, forHTTPHeaderField: "X-OpenAI-Target-Path")
            request.setValue(url.path, forHTTPHeaderField: "X-OpenAI-Target-Route")
            return
        }

        if shouldUseJSONAccept(for: url),
           request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue(jsonAcceptValue, forHTTPHeaderField: "Accept")
        }
    }

    private static func shouldIncludeOriginHeader(for requestKind: RequestKind) -> Bool {
        switch requestKind {
        case .workspaceSwitch, .currentSession:
            return false
        case .backendAPI, .other:
            return true
        }
    }

    private static func refererValue(for url: URL?) -> String {
        if url?.path.hasPrefix("/backend-api/wham/") == true {
            return ChatGPTWebURLs.codexPage.absoluteString
        }

        return ChatGPTWebURLs.usagePage.absoluteString
    }
}
