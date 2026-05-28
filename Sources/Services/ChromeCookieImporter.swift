import Foundation

struct ChromeDevToolsCookie: Decodable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Double?
    let httpOnly: Bool
    let secure: Bool
}

enum ChromeCookieImporter {
    private static let sessionCookieBaseNames: Set<String> = [
        "next-auth.session-token",
        "authjs.session-token",
        "__secure-next-auth.session-token",
        "__host-next-auth.session-token",
        "__secure-authjs.session-token",
        "__host-authjs.session-token",
    ]

    static func chatGPTHTTPCookies(
        from cookies: [ChromeDevToolsCookie],
        scope: URL = ChatGPTWebURLs.cookieScope
    ) throws -> [HTTPCookie] {
        let host = scope.host?.lowercased() ?? "chatgpt.com"
        let importedCookies = cookies
            .filter { isChatGPTCookieDomain($0.domain, host: host) }
            .compactMap(makeHTTPCookie)

        guard importedCookies.contains(where: isSessionCookie) else {
            throw ChatGPTAPIError.unauthorized
        }

        return importedCookies
    }

    @MainActor
    static func storeChatGPTCookies(
        from cookies: [ChromeDevToolsCookie],
        in sessionStore: WebSessionStore
    ) async throws -> Int {
        let importedCookies = try chatGPTHTTPCookies(from: cookies)
        await sessionStore.storeCookies(importedCookies)
        return importedCookies.count
    }

    private static func isChatGPTCookieDomain(
        _ domain: String,
        host: String
    ) -> Bool {
        let normalizedDomain = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedDomain == host || normalizedDomain == ".\(host)"
    }

    private static func makeHTTPCookie(
        from chromeCookie: ChromeDevToolsCookie
    ) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: chromeCookie.name,
            .value: chromeCookie.value,
            .domain: chromeCookie.domain,
            .path: chromeCookie.path.isEmpty ? "/" : chromeCookie.path,
        ]

        if let expires = chromeCookie.expires, expires > 0 {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }

        if chromeCookie.secure {
            properties[.secure] = "TRUE"
        }

        if chromeCookie.httpOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        return HTTPCookie(properties: properties)
    }

    private static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        let name = cookie.name.lowercased()
        if sessionCookieBaseNames.contains(name) {
            return true
        }

        guard let chunkSeparatorIndex = name.lastIndex(of: ".") else {
            return false
        }

        let baseName = String(name[..<chunkSeparatorIndex])
        let chunkSuffix = name[name.index(after: chunkSeparatorIndex)...]
        return sessionCookieBaseNames.contains(baseName)
            && chunkSuffix.isEmpty == false
            && chunkSuffix.allSatisfy(\.isNumber)
    }
}
