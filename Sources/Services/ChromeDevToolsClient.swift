import Foundation

@MainActor
final class ChromeDevToolsClient {
    typealias Request = @MainActor (Data) async throws -> Data
    private let webSocketTask: URLSessionWebSocketTask?
    private let request: Request?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1

    init(
        webSocketURL: URL,
        urlSession: URLSession = .shared
    ) {
        request = nil
        webSocketTask = urlSession.webSocketTask(with: webSocketURL)
        webSocketTask?.resume()
    }

    init(request: @escaping Request) { self.request = request; webSocketTask = nil }

    func setCookies(_ cookies: [BackupCookie]) async throws {
        guard cookies.count <= 10_000, cookies.allSatisfy({ $0.isValid(for: .codex) }) else { throw CloudSessionError.invalidPayload }
        let values = try cookies.filter { $0.expires.map { $0 > .now } ?? true }.map { cookie -> ChromeCookieParameter in
            if let expiry = cookie.expires?.timeIntervalSince1970, expiry < 0 || expiry > 253_402_300_799 { throw CloudSessionError.invalidPayload }
            let sameSite = cookie.sameSite.map { $0.lowercased() }
            guard sameSite == nil || ["strict", "lax", "none"].contains(sameSite!) else { throw CloudSessionError.invalidPayload }
            return .init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                secure: cookie.secure, httpOnly: cookie.httpOnly, expires: cookie.expires?.timeIntervalSince1970,
                sameSite: sameSite.map { $0.prefix(1).uppercased() + $0.dropFirst() })
        }
        let _: ChromeDevToolsEmptyResult = try await send(method: "Storage.setCookies", params: .init(cookies: values))
    }

    func deleteCookie(_ cookie: ChromeDevToolsCookie) async throws {
        guard Self.isProviderCookie(cookie) else { throw CloudSessionError.invalidPayload }
        // Browser-target CDP exposes Storage, not the page-only Network domain.
        // Expiring the exact tuple removes it without clearing other domains.
        let expired = ChromeCookieParameter(name: cookie.name, value: "", domain: cookie.domain, path: cookie.path,
            secure: cookie.secure, httpOnly: cookie.httpOnly, expires: 1, sameSite: nil)
        let _: ChromeDevToolsEmptyResult = try await send(method: "Storage.setCookies", params: .init(cookies: [expired]))
    }

    static func isProviderCookie(_ cookie: ChromeDevToolsCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "chatgpt.com" || domain.hasSuffix(".chatgpt.com")
    }

    static func connect(
        versionURL: URL,
        urlSession: URLSession = .shared
    ) async throws -> ChromeDevToolsClient {
        let response = try await fetchVersionEndpoint(
            versionURL: versionURL,
            urlSession: urlSession
        )

        guard let webSocketURL = response.webSocketDebuggerUrl else {
            throw ChatGPTAPIError.invalidResponse
        }

        return ChromeDevToolsClient(
            webSocketURL: webSocketURL,
            urlSession: urlSession
        )
    }

    func getCookies() async throws -> [ChromeDevToolsCookie] {
        let response: ChromeDevToolsCookieResponse = try await send(method: "Storage.getCookies")
        return response.cookies
    }

    func clearCookies() async throws {
        let _: ChromeDevToolsEmptyResult = try await send(method: "Storage.clearCookies")
    }

    func closeBrowser() async throws {
        let _: ChromeDevToolsEmptyResult = try await send(method: "Browser.close")
    }

    private func send<Result: Decodable>(
        method: String, params: ChromeCookieParameters? = nil
    ) async throws -> Result {
        let requestID = nextRequestID
        nextRequestID += 1

        let request = ChromeDevToolsRequest(
            id: requestID,
            method: method, params: params
        )
        let payload = try encoder.encode(request)

        if let exchange = self.request {
            let response = try decoder.decode(ChromeDevToolsResponse<Result>.self, from: await exchange(payload))
            guard response.id == requestID, response.error == nil, let result = response.result else { throw ChatGPTAPIError.invalidResponse }
            return result
        }
        guard let webSocketTask else { throw ChatGPTAPIError.invalidResponse }

        guard let message = String(data: payload, encoding: .utf8) else {
            throw ChatGPTAPIError.invalidResponse
        }

        try await webSocketTask.send(.string(message))

        while true {
            let receivedMessage = try await webSocketTask.receive()
            let responseData: Data

            switch receivedMessage {
            case let .data(data):
                responseData = data
            case let .string(string):
                responseData = Data(string.utf8)
            @unknown default:
                throw ChatGPTAPIError.invalidResponse
            }

            let response = try decoder.decode(
                ChromeDevToolsResponse<Result>.self,
                from: responseData
            )

            guard response.id == requestID else {
                continue
            }

            if let error = response.error {
                throw ChatGPTAPIError.network(error.message)
            }

            guard let result = response.result else {
                throw ChatGPTAPIError.invalidResponse
            }

            return result
        }
    }

    private static func fetchVersionEndpoint(
        versionURL: URL,
        urlSession: URLSession
    ) async throws -> ChromeDevToolsVersionEndpointResponse {
        var request = URLRequest(url: versionURL)
        request.timeoutInterval = 5

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ChatGPTAPIError.invalidResponse
        }

        return try JSONDecoder().decode(
            ChromeDevToolsVersionEndpointResponse.self,
            from: data
        )
    }
}

private struct ChromeDevToolsVersionEndpointResponse: Decodable {
    let webSocketDebuggerUrl: URL?
}

private struct ChromeDevToolsRequest: Encodable {
    let id: Int
    let method: String
    let params: ChromeCookieParameters?
}

private struct ChromeCookieParameters: Encodable {
    let cookies: [ChromeCookieParameter]
}

private struct ChromeCookieParameter: Encodable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let httpOnly: Bool
    let expires: Double?
    let sameSite: String?
}

private struct ChromeDevToolsResponse<Result: Decodable>: Decodable {
    let id: Int?
    let result: Result?
    let error: ChromeDevToolsError?
}

private struct ChromeDevToolsError: Decodable {
    let message: String
}

private struct ChromeDevToolsCookieResponse: Decodable {
    let cookies: [ChromeDevToolsCookie]
}

private struct ChromeDevToolsEmptyResult: Decodable {}
