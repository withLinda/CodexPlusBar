import Foundation

protocol OpenCodeOpenAICredentialVerifying: Sendable {
    func verify(_ auth: OpenCodeOpenAIAuth) async throws
    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth
}

enum OpenCodeOpenAIVerificationError: LocalizedError, Equatable {
    case unauthorized, reauthenticationRequired, accessDenied
    case unavailable, httpStatus(Int), invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized, .reauthenticationRequired:
            return "OpenAI rejected this saved sign-in. Sign in to this account again in OpenChamber, then save its current sign-in here."
        case .accessDenied:
            return "OpenAI denied access to this account. Check its OpenAI connection in OpenChamber."
        case .unavailable:
            return "OpenAI could not be reached for verification. Check your connection and try again."
        case .httpStatus(let code):
            return "OpenAI verification returned HTTP \(code). Try again later."
        case .invalidResponse:
            return "OpenAI returned an unreadable verification response. Try again later."
        }
    }
}

/// Uses the same account-scoped usage request as OpenChamber, independently of
/// the profile's browser cookies. Never sends credentials to a redirect or logs bodies.
struct OpenCodeOpenAICredentialVerifier: OpenCodeOpenAICredentialVerifying {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let request: Request
    private let now: @Sendable () -> Date

    init(request: @escaping Request = Self.send, now: @escaping @Sendable () -> Date = { .now }) {
        self.request = request
        self.now = now
    }

    func verify(_ auth: OpenCodeOpenAIAuth) async throws {
        _ = try auth.identity()
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(auth.access)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200: break
        case 401: throw OpenCodeOpenAIVerificationError.unauthorized
        case 403: throw OpenCodeOpenAIVerificationError.accessDenied
        default: throw OpenCodeOpenAIVerificationError.httpStatus(response.statusCode)
        }
        // A 200 login page, proxy page, or unrelated JSON is not verification.
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["rate_limit"] is [String: Any] else {
            throw OpenCodeOpenAIVerificationError.invalidResponse
        }
    }

    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth {
        let identity = try auth.identity()
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // OpenCode's ChatGPT OAuth client, not a Codex CLI token exchange.
        request.httpBody = Data([
            ("grant_type", "refresh_token"),
            ("refresh_token", auth.refresh),
            ("client_id", "app_EMoamEEZ73f0CkXaXp7hrann"),
        ].map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&").utf8)
        let (data, response) = try await perform(request)
        if response.statusCode == 400 || response.statusCode == 401 {
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = payload?["error"] as? String
                ?? (payload?["error"] as? [String: Any])?["code"] as? String
            if response.statusCode == 401 || ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code ?? "") {
                throw OpenCodeOpenAIVerificationError.reauthenticationRequired
            }
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 403 { throw OpenCodeOpenAIVerificationError.accessDenied }
            throw OpenCodeOpenAIVerificationError.httpStatus(response.statusCode)
        }
        struct Tokens: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else {
            throw OpenCodeOpenAIVerificationError.invalidResponse
        }
        let lifetime = tokens.expires_in ?? 3600
        let expiry = (now().timeIntervalSince1970 + lifetime) * 1000
        guard lifetime.isFinite, lifetime > 0, expiry.isFinite, expiry >= 0, expiry < Double(Int64.max) else {
            throw OpenCodeOpenAIVerificationError.invalidResponse
        }
        let refreshed = OpenCodeOpenAIAuth(type: "oauth", refresh: tokens.refresh_token ?? auth.refresh,
                                          access: tokens.access_token, expires: Int64(expiry), accountId: auth.accountId)
        guard try identity.matches(refreshed.identity()) else { throw OpenCodeOpenAIAuthError.identityMismatch }
        return refreshed
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = request
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            // Preserve a received refresh response even if cancellation arrives
            // at this boundary; its rotated token must be saved before stopping.
            return try await self.request(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OpenCodeOpenAIVerificationError {
            throw error
        } catch {
            throw OpenCodeOpenAIVerificationError.unavailable
        }
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OpenCodeOpenAIVerificationError.invalidResponse }
        return (data, response)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
