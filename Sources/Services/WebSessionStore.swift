import Foundation
import WebKit

@MainActor
final class WebSessionStore {
    private static let currentAccountCookieName = "_account"
    private let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
    }

    func cookies(for url: URL) async -> [HTTPCookie] {
        let allCookies = await dataStore.httpCookieStore.allCookies()
        guard let host = url.host?.lowercased() else {
            return []
        }

        return allCookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let trimmedDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let isMatchingDomain = host == trimmedDomain || host.hasSuffix(".\(trimmedDomain)")
            let isSecureMatch = cookie.isSecure == false || url.scheme?.lowercased() == "https"
            let isPathMatch = url.path.hasPrefix(cookie.path)
            return isMatchingDomain && isSecureMatch && isPathMatch
        }
    }

    func cookieValue(named name: String, for url: URL = ChatGPTWebURLs.cookieScope) async -> String? {
        let cookies = await cookies(for: url)
        return cookies.first(where: { $0.name == name })?.value
    }

    func currentAccountCookieValue() async -> String? {
        await cookieValue(named: Self.currentAccountCookieName)
    }

    func setCurrentAccountCookie(_ accountID: String) async throws {
        let scope = ChatGPTWebURLs.cookieScope
        let existingCookies = await matchingCookies(
            named: Self.currentAccountCookieName,
            for: scope
        )
        let template = existingCookies.first

        guard let cookie = Self.makeCurrentAccountCookie(
            accountID: accountID,
            template: template
        ) else {
            throw ChatGPTAPIError.unsupported("The app could not update the ChatGPT account cookie.")
        }

        for existingCookie in existingCookies {
            await dataStore.httpCookieStore.deleteCookieAsync(existingCookie)
        }

        await dataStore.httpCookieStore.setCookieAsync(cookie)
    }

    func storeResponseCookies(from response: HTTPURLResponse, for url: URL) async {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { partialResult, item in
            guard let key = item.key as? String, let value = item.value as? String else {
                return
            }
            partialResult[key] = value
        }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        await storeCookies(cookies)
    }

    func storeCookies(_ cookies: [HTTPCookie]) async {
        for cookie in cookies {
            await dataStore.httpCookieStore.setCookieAsync(cookie)
        }
    }

    func replaceCookies(_ cookies: [HTTPCookie], for url: URL) async {
        guard let host = url.host?.lowercased() else {
            await storeCookies(cookies)
            return
        }

        let existingCookies = await dataStore.httpCookieStore.allCookies()
        for cookie in existingCookies where Self.normalizedDomain(cookie.domain) == host {
            await dataStore.httpCookieStore.deleteCookieAsync(cookie)
        }

        await storeCookies(cookies)
    }

    func clear() async {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    private func matchingCookies(named name: String, for url: URL) async -> [HTTPCookie] {
        let cookies = await cookies(for: url)
        return cookies.filter { $0.name == name }
    }

    private static func normalizedDomain(_ domain: String) -> String {
        let lowercasedDomain = domain.lowercased()
        return lowercasedDomain.hasPrefix(".")
            ? String(lowercasedDomain.dropFirst())
            : lowercasedDomain
    }

    private static func makeCurrentAccountCookie(
        accountID: String,
        template: HTTPCookie?
    ) -> HTTPCookie? {
        var properties = template?.properties ?? [:]
        properties[.name] = currentAccountCookieName
        properties[.value] = accountID
        properties[.domain] = {
            if let templateDomain = template?.domain,
               templateDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return templateDomain
            }

            return "chatgpt.com"
        }()
        properties[.path] = {
            if let templatePath = template?.path,
               templatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return templatePath
            }

            return "/"
        }()

        if template?.isSecure ?? true {
            properties[.secure] = "TRUE"
        } else {
            properties.removeValue(forKey: .secure)
        }

        return HTTPCookie(properties: properties)
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func setCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    func deleteCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            delete(cookie) {
                continuation.resume()
            }
        }
    }
}
