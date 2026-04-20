import Foundation

@MainActor
protocol ChatGPTAuthContextWritable: AnyObject {
    func updateAuthContext(_ context: ChatGPTAuthContext?)
}

@MainActor
final class CookieBackedTransport: HTTPTransport, ChatGPTAuthContextWritable {
    private let sessionStore: WebSessionStore
    private let urlSession: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let logger: NetworkTraceLogger
    private var authContext: ChatGPTAuthContext?

    init(
        sessionStore: WebSessionStore = WebSessionStore(),
        urlSession: URLSession? = nil,
        logger: NetworkTraceLogger = .live
    ) {
        self.sessionStore = sessionStore
        if let urlSession {
            self.urlSession = urlSession
            self.cookieStorage = urlSession.configuration.httpCookieStorage ?? .shared
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            self.cookieStorage = configuration.httpCookieStorage ?? .shared
            self.urlSession = URLSession(configuration: configuration)
        }
        self.logger = logger
    }

    func updateAuthContext(_ context: ChatGPTAuthContext?) {
        authContext = context
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        guard let url = request.url else {
            throw ChatGPTAPIError.missingURL
        }

        let cookies = await sessionStore.cookies(for: url)
        seedCookieStorage(with: cookies)

        var signedRequest = ChatGPTRequestSigner.sign(
            request,
            cookies: cookies,
            authContext: authContext
        )
        signedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        signedRequest.httpShouldHandleCookies = true

        logger.logRequest(signedRequest)

        do {
            let (data, response) = try await urlSession.data(for: signedRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChatGPTAPIError.invalidResponse
            }

            await sessionStore.storeCookies(cookieStorage.cookies ?? [])
            logger.logResponse(httpResponse, data: data)

            switch httpResponse.statusCode {
            case 200 ... 299:
                return HTTPResponseData(data: data, response: httpResponse)
            case 401, 403:
                throw ChatGPTAPIError.unauthorized
            default:
                throw ChatGPTAPIError.httpStatus(httpResponse.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw ChatGPTAPIError.map(error)
        }
    }

    private func seedCookieStorage(with cookies: [HTTPCookie]) {
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
    }
}
