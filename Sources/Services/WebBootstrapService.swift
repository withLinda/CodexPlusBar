import Foundation

struct ChatGPTWebBootstrap: Equatable, Sendable {
    let authStatus: String?
    let accessToken: String?
    let accountID: String?
    let expiresAt: Date?
    let clientVersion: String?
    let locale: String?

    var isLoggedIn: Bool {
        authStatus == "logged_in"
    }

    var hasUsableSession: Bool {
        accessToken?.isEmpty == false && accountID?.isEmpty == false
    }
}

struct WebBootstrapService {
    private let transport: HTTPTransport

    init(transport: HTTPTransport) {
        self.transport = transport
    }

    @MainActor
    func fetchBootstrap() async throws -> ChatGPTWebBootstrap {
        let response = try await transport.data(for: Self.makeRequest())
        return try Self.parseBootstrap(from: response.data)
    }

    static func makeRequest() -> URLRequest {
        var request = URLRequest(url: ChatGPTWebURLs.usagePage)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    static func parseBootstrap(from data: Data) throws -> ChatGPTWebBootstrap {
        let html = String(decoding: data, as: UTF8.self)
        let clientVersion = firstMatch(
            in: html,
            pattern: #"data-build="([^"]+)""#
        )

        guard let rawJSON = firstMatch(
            in: html,
            pattern: #"<script[^>]*id="client-bootstrap"[^>]*>(.*?)</script>"#,
            options: [.dotMatchesLineSeparators]
        ) else {
            return ChatGPTWebBootstrap(
                authStatus: nil,
                accessToken: nil,
                accountID: nil,
                expiresAt: nil,
                clientVersion: clientVersion,
                locale: nil
            )
        }

        do {
            let payload = try JSONDecoder.chatGPTAPI.decode(ChatGPTBootstrapPayload.self, from: Data(rawJSON.utf8))
            return ChatGPTWebBootstrap(
                authStatus: payload.authStatus,
                accessToken: payload.session?.accessToken,
                accountID: payload.session?.account?.resolvedID,
                expiresAt: payload.session?.expires,
                clientVersion: clientVersion,
                locale: payload.locale
            )
        } catch {
            throw ChatGPTAPIError.decoding("The app could not read the ChatGPT web bootstrap.")
        }
    }

    private static func firstMatch(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
    }
}

private struct ChatGPTBootstrapPayload: Decodable {
    let authStatus: String?
    let session: ChatGPTBootstrapSession?
    let locale: String?
}

private struct ChatGPTBootstrapSession: Decodable {
    let accessToken: String?
    let expires: Date?
    let account: ChatGPTBootstrapAccount?
}

private struct ChatGPTBootstrapAccount: Decodable {
    let id: String?
    let accountID: String?

    var resolvedID: String? {
        if let id, id.isEmpty == false {
            return id
        }

        return accountID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
    }
}
