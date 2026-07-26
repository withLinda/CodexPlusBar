import Foundation

struct ClaudeRequestSigner {
    static func sign(
        _ request: URLRequest,
        cookies: [HTTPCookie]
    ) -> URLRequest {
        var signedRequest = request
        signedRequest.httpShouldHandleCookies = false

        if signedRequest.value(forHTTPHeaderField: "Accept") == nil {
            signedRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        signedRequest.setValue(
            ClaudeWebURLs.usagePage.absoluteString,
            forHTTPHeaderField: "Referer"
        )
        signedRequest.setValue(nil, forHTTPHeaderField: "Origin")
        signedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        signedRequest.setValue(nil, forHTTPHeaderField: "ChatGPT-Account-ID")
        signedRequest.setValue(nil, forHTTPHeaderField: "OAI-Language")
        signedRequest.setValue(nil, forHTTPHeaderField: "OAI-Device-Id")
        signedRequest.setValue(nil, forHTTPHeaderField: "OAI-Client-Version")

        HTTPCookie.requestHeaderFields(with: cookies).forEach { key, value in
            signedRequest.setValue(value, forHTTPHeaderField: key)
        }

        return signedRequest
    }
}
