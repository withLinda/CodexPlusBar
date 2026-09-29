import Foundation

protocol CodexSignInVerifying: Sendable {
    func verify(_ signIn: CodexSignIn) async throws
    func refresh(_ signIn: CodexSignIn) async throws -> CodexSignIn
}

struct CodexSignInVerifier: CodexSignInVerifying {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let request: Request
    private let now: @Sendable () -> Date

    init(request: @escaping Request = Self.send, now: @escaping @Sendable () -> Date = { .now }) {
        self.request = request
        self.now = now
    }

    func verify(_ signIn: CodexSignIn) async throws {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(signIn.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(signIn.identity.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 { throw CodexSignInError.unauthorized }
            throw CodexSignInError.httpStatus(response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["rate_limit"] is [String: Any] else { throw CodexSignInError.invalidResponse }
    }

    func refresh(_ signIn: CodexSignIn) async throws -> CodexSignIn {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [("grant_type", "refresh_token"), ("refresh_token", signIn.refreshToken),
                      ("client_id", "app_EMoamEEZ73f0CkXaXp7hrann")]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else {
            if [400, 401].contains(response.statusCode) { throw CodexSignInError.unauthorized }
            throw CodexSignInError.httpStatus(response.statusCode)
        }
        struct Tokens: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { throw CodexSignInError.invalidResponse }
        // No cancellation check after receiving rotated tokens; the transaction must persist them first.
        return try signIn.replacingTokens(access: tokens.access_token, refresh: tokens.refresh_token, idToken: tokens.id_token, at: now())
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = request
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do { return try await self.request(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as CodexSignInError { throw error }
        catch { throw CodexSignInError.unavailable }
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodexSignInError.invalidResponse }
        return (data, response)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
