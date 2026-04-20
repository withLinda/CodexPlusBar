import Foundation

struct AuthSessionService {
    private let transport: HTTPTransport
    private let sessionStore: WebSessionStore
    private let bootstrapService: WebBootstrapService

    init(
        transport: HTTPTransport,
        sessionStore: WebSessionStore,
        bootstrapService: WebBootstrapService? = nil
    ) {
        self.transport = transport
        self.sessionStore = sessionStore
        self.bootstrapService = bootstrapService ?? WebBootstrapService(transport: transport)
    }

    @MainActor
    func fetchCurrentSession(fallback: ChatGPTAuthContext? = nil) async throws -> ChatGPTAuthContext {
        let response = try await transport.data(for: Self.makeCurrentSessionRequest())
        let decoded = try Self.decodeEnvelope(from: response.data)

        let needsBootstrap = fallback?.clientVersion == nil
            || Self.resolvedAccessToken(from: decoded) == nil
            || Self.resolvedAccountID(from: decoded) == nil

        let bootstrap = needsBootstrap ? (try? await bootstrapService.fetchBootstrap()) : nil
        let deviceID = await sessionStore.cookieValue(named: "oai-did")

        return try Self.resolveContext(
            from: decoded,
            bootstrap: bootstrap,
            fallback: fallback,
            deviceID: deviceID
        )
    }

    @MainActor
    func switchWorkspaceAndRefreshSession(
        workspaceID: String,
        fallback: ChatGPTAuthContext? = nil,
        requestTimeout: TimeInterval? = nil
    ) async throws -> ChatGPTAuthContext {
        try await sessionStore.setCurrentAccountCookie(workspaceID)
        let response = try await transport.data(
            for: Self.makeWorkspaceSwitchRequest(
                workspaceID: workspaceID,
                timeoutInterval: requestTimeout
            )
        )
        let decoded = try Self.decodeEnvelope(from: response.data)
        let deviceID = await sessionStore.cookieValue(named: "oai-did")

        if Self.resolvedAccessToken(from: decoded) != nil,
           Self.resolvedAccountID(from: decoded) != nil {
            let switchedContext = try Self.resolveContext(
                from: decoded,
                bootstrap: nil,
                fallback: fallback,
                deviceID: deviceID
            )
            return try Self.requireSwitchedWorkspace(
                switchedContext,
                requestedWorkspaceID: workspaceID
            )
        }

        let refreshedContext = try await fetchCurrentSession(fallback: fallback)
        return try Self.requireSwitchedWorkspace(
            refreshedContext,
            requestedWorkspaceID: workspaceID
        )
    }

    static func makeCurrentSessionRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/api/auth/session")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    static func makeWorkspaceSwitchRequest(
        workspaceID: String,
        timeoutInterval: TimeInterval? = nil
    ) -> URLRequest {
        var components = URLComponents(string: "https://chatgpt.com/api/auth/session")!
        components.queryItems = [
            URLQueryItem(name: "exchange_workspace_token", value: "true"),
            URLQueryItem(name: "workspace_id", value: workspaceID),
            URLQueryItem(name: "reason", value: "setCurrentAccount"),
        ]

        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let timeoutInterval, timeoutInterval > 0 {
            request.timeoutInterval = timeoutInterval
        }
        return request
    }

    static func decodeAuthContext(
        from data: Data,
        bootstrap: ChatGPTWebBootstrap? = nil,
        fallback: ChatGPTAuthContext? = nil,
        deviceID: String? = nil
    ) throws -> ChatGPTAuthContext {
        let decoded = try decodeEnvelope(from: data)
        return try resolveContext(
            from: decoded,
            bootstrap: bootstrap,
            fallback: fallback,
            deviceID: deviceID
        )
    }

    private static func decodeEnvelope(from data: Data) throws -> AuthSessionEnvelope {
        do {
            return try JSONDecoder.chatGPTAPI.decode(AuthSessionEnvelope.self, from: data)
        } catch {
            throw ChatGPTAPIError.decoding("The app could not read the ChatGPT auth session.")
        }
    }

    private static func resolveContext(
        from decoded: AuthSessionEnvelope,
        bootstrap: ChatGPTWebBootstrap?,
        fallback: ChatGPTAuthContext?,
        deviceID: String?
    ) throws -> ChatGPTAuthContext {
        if let bootstrap {
            if bootstrap.authStatus != nil, bootstrap.isLoggedIn == false {
                throw ChatGPTAPIError.unauthorized
            }

            if bootstrap.hasUsableSession == false {
                throw ChatGPTAPIError.unauthorized
            }
        }

        guard let accessToken = resolvedAccessToken(from: decoded) ?? bootstrap?.accessToken,
              let accountID = resolvedAccountID(from: decoded) ?? bootstrap?.accountID
        else {
            throw ChatGPTAPIError.unauthorized
        }

        let session = decoded.session ?? decoded.asSessionPayload
        let language = firstNonEmpty(decoded.locale, bootstrap?.locale, fallback?.language) ?? "en-US"

        return ChatGPTAuthContext(
            accessToken: accessToken,
            accountID: accountID,
            expiresAt: session.expires ?? bootstrap?.expiresAt ?? fallback?.expiresAt,
            deviceID: firstNonEmpty(deviceID, fallback?.deviceID),
            clientVersion: firstNonEmpty(bootstrap?.clientVersion, fallback?.clientVersion),
            language: language
        )
    }

    private static func resolvedAccessToken(from decoded: AuthSessionEnvelope) -> String? {
        firstNonEmpty(decoded.session?.accessToken, decoded.accessToken)
    }

    private static func resolvedAccountID(from decoded: AuthSessionEnvelope) -> String? {
        firstNonEmpty(decoded.session?.account?.resolvedID, decoded.account?.resolvedID)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } ?? nil
    }

    private static func requireSwitchedWorkspace(
        _ context: ChatGPTAuthContext,
        requestedWorkspaceID: String
    ) throws -> ChatGPTAuthContext {
        guard context.accountID == requestedWorkspaceID else {
            throw ChatGPTAPIError.unsupported(
                "ChatGPT kept the active session on account \(context.accountID) while the app tried to switch to \(requestedWorkspaceID)."
            )
        }

        return context
    }
}

private struct AuthSessionEnvelope: Decodable {
    let accessToken: String?
    let expires: Date?
    let account: AuthSessionAccount?
    let session: AuthSessionPayload?
    let locale: String?

    var asSessionPayload: AuthSessionPayload {
        AuthSessionPayload(
            accessToken: accessToken,
            expires: expires,
            account: account
        )
    }
}

private struct AuthSessionPayload: Decodable {
    let accessToken: String?
    let expires: Date?
    let account: AuthSessionAccount?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case expires
        case account
    }
}

private struct AuthSessionAccount: Decodable {
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
