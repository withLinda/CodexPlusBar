import Foundation

struct ChromeDevToolsBrowserVersion: Decodable, Equatable, Sendable {
    let protocolVersion: String?
    let product: String?
    let userAgent: String?
    let jsVersion: String?
}

@MainActor
final class ChromeDevToolsClient {
    private let webSocketTask: URLSessionWebSocketTask
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1

    init(
        webSocketURL: URL,
        urlSession: URLSession = .shared
    ) {
        webSocketTask = urlSession.webSocketTask(with: webSocketURL)
        webSocketTask.resume()
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

    func getVersion() async throws -> ChromeDevToolsBrowserVersion {
        try await send(method: "Browser.getVersion")
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

    func cancel() {
        webSocketTask.cancel(with: .goingAway, reason: nil)
    }

    private func send<Result: Decodable>(
        method: String
    ) async throws -> Result {
        let requestID = nextRequestID
        nextRequestID += 1

        let request = ChromeDevToolsRequest(
            id: requestID,
            method: method
        )
        let payload = try encoder.encode(request)

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
