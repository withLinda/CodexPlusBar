import Foundation

@MainActor
protocol PlusProfileRuntimeProviding: AnyObject {
    func runtime(for profile: PlusProfile) -> PlusProfileRuntime
    func clearSession(for profile: PlusProfile) async
    func removeProfileData(for profile: PlusProfile) async throws
}

extension ProfileRuntimeRegistry: PlusProfileRuntimeProviding {}

@MainActor
protocol PlusProfileDataServing: AnyObject {
    func openAppAuthorization(_ url: URL, for profile: PlusProfile) async throws
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult
    func openChromeAccountPage(for profile: PlusProfile) async throws
    func openChromeSignIn(for profile: PlusProfile) async throws
    func openChromePasskeySetup(for profile: PlusProfile) async throws
    func syncChromeSession(for profile: PlusProfile) async throws
    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool
    func closeChromeSignIn(for profile: PlusProfile) async
    func clearSession(for profile: PlusProfile) async throws
    func removeProfileData(for profile: PlusProfile) async throws
    func captureSavedSession(for profile: PlusProfile) async throws -> CloudSessionPayload?
}

extension PlusProfileDataServing {
    func openAppAuthorization(_ url: URL, for profile: PlusProfile) async throws { throw AppSignInRepairError.helperUnavailable }
    func captureSavedSession(for profile: PlusProfile) async throws -> CloudSessionPayload? { nil }
}

@MainActor
final class PlusProfileDataService: PlusProfileDataServing {
    private let runtimeProvider: PlusProfileRuntimeProviding
    private let chromeSessionManager: ChromeSessionManaging
    private var operating: Set<UUID> = []
    private var browserProof: [UUID: (store: UUID, payload: CloudSessionPayload)] = [:]

    init(
        runtimeProvider: PlusProfileRuntimeProviding = ProfileRuntimeRegistry(),
        chromeSessionManager: ChromeSessionManaging = DefaultChromeSessionManager()
    ) {
        self.runtimeProvider = runtimeProvider
        self.chromeSessionManager = chromeSessionManager
    }

    func openAppAuthorization(_ url: URL, for profile: PlusProfile) async throws {
        try await chromeSessionManager.openAppAuthorization(url, for: profile)
    }

    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id); CloudSavedSessionChange.committed(); CloudSavedSessionChange.released() }
        guard profile.provider == .codex else {
            throw ChatGPTAPIError.unsupported("This saved provider is inactive.")
        }
        let runtime = runtimeProvider.runtime(for: profile)
        let authSessionService = AuthSessionService(
            transport: runtime.transport,
            sessionStore: runtime.sessionStore
        )
        let context = try await authSessionService.fetchCurrentSession(fallback: runtime.authContext)
        runtime.updateAuthContext(context)

        let response = try await runtime.transport.data(
            for: Self.makeUsageRequest(accountID: context.accountID)
        )
        let snapshot = try WorkspaceLimitService.decodeSnapshot(
            from: response.data,
            workspaceID: context.accountID
        )
        let expiryRefresh = await Self.fetchExpiryRefresh(
            accountID: snapshot.accountID,
            transport: runtime.transport
        )

        await rememberBrowser(profile, context: context, runtime: runtime)

        return PlusProfileRefreshResult(
            usage: PlusProfileUsage(
                accountID: snapshot.accountID,
                planType: snapshot.planType,
                primaryWindow: snapshot.primaryWindow,
                secondaryWindow: snapshot.secondaryWindow,
                fetchedAt: snapshot.fetchedAt
            ),
            detectedNote: Self.makeDetectedNote(
                planType: snapshot.planType,
                accountID: snapshot.accountID
            ),
            expiryRefresh: expiryRefresh.display,
            selectorObservation: SelectorObservation.make(context: context, snapshot: snapshot,
                catalog: expiryRefresh.catalog, entitlementObservedAt: expiryRefresh.observedAt,
                nativeIdentity: profile.openCodeOpenAIAccount)
        )
    }

    func clearSession(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id) }
        browserProof.removeValue(forKey: profile.id)
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        await runtimeProvider.clearSession(for: profile)
        try await chromeSessionManager.clearCookies(for: profile)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id) }
        browserProof.removeValue(forKey: profile.id)
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        try await runtimeProvider.removeProfileData(for: profile)
        try await chromeSessionManager.removeProfileData(for: profile)
    }

    func openChromeSignIn(for profile: PlusProfile) async throws {
        try await chromeSessionManager.openSignIn(for: profile)
    }

    func openChromeAccountPage(for profile: PlusProfile) async throws {
        try await chromeSessionManager.openAccountPage(for: profile)
    }

    func openChromePasskeySetup(for profile: PlusProfile) async throws {
        try await chromeSessionManager.openPasskeySetup(for: profile)
    }

    func syncChromeSession(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id); CloudSavedSessionChange.committed(); CloudSavedSessionChange.released() }
        browserProof.removeValue(forKey: profile.id)
        guard profile.provider == .codex else {
            throw ChatGPTAPIError.unsupported("This saved provider is inactive.")
        }
        let runtime = runtimeProvider.runtime(for: profile)
        _ = try await chromeSessionManager.syncCookies(
            for: profile,
            into: runtime.sessionStore
        )

        do {
            let authSessionService = AuthSessionService(
                transport: runtime.transport,
                sessionStore: runtime.sessionStore
            )
            let context = try await authSessionService.fetchCurrentSession(
                fallback: runtime.authContext
            )
            runtime.updateAuthContext(context)

            await rememberBrowser(profile, context: context, runtime: runtime)

            await chromeSessionManager.closeSignIn(for: profile)
        } catch {
            if ChatGPTAPIError.map(error) == .unauthorized {
                try? await chromeSessionManager.openSignIn(for: profile)
            }

            throw error
        }
    }

    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool {
        await chromeSessionManager.waitForSignInToFinish(for: profile)
    }

    func closeChromeSignIn(for profile: PlusProfile) async {
        await chromeSessionManager.closeSignIn(for: profile)
    }

    private func rememberBrowser(_ profile: PlusProfile, context: ChatGPTAuthContext, runtime: PlusProfileRuntime) async {
        guard let userID = context.userID else { browserProof.removeValue(forKey: profile.id); return }
        let cookies = await runtime.sessionStore.portableChatGPTCookies()
        let payload = CloudSessionPayload.browser(cookies: cookies,
            identity: .init(accountID: context.accountID, userID: userID), accessToken: context.accessToken)
        guard let validated = try? payload.validated(), runtime.authContext == context else {
            browserProof.removeValue(forKey: profile.id); return
        }
        browserProof[profile.id] = (profile.webDataStoreID, validated)
    }

    func captureSavedSession(for profile: PlusProfile) async throws -> CloudSessionPayload? {
        guard profile.provider == .codex, let proof = browserProof[profile.id], proof.store == profile.webDataStoreID else { return nil }
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id) }
        guard case .browser(_, let identity, let token) = proof.payload else { return nil }
        let runtime = runtimeProvider.runtime(for: profile)
        let cookies = await runtime.sessionStore.portableChatGPTCookies()
        let current = try CloudSessionPayload.browser(cookies: cookies, identity: identity, accessToken: token).validated()
        guard current == proof.payload else { return nil }
        return current
    }

    private static func makeUsageRequest(accountID: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        return request
    }

    private static func makeDetectedNote(planType: String, accountID: String) -> String {
        let trimmedPlan = DisplayFormatter.plan(planType)
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortAccountID: String

        if trimmedAccountID.count > 6 {
            shortAccountID = String(trimmedAccountID.suffix(6))
        } else if trimmedAccountID.isEmpty {
            shortAccountID = "profile"
        } else {
            shortAccountID = trimmedAccountID
        }

        return "\(trimmedPlan) · \(shortAccountID)"
    }

    private static func fetchExpiryRefresh(
        accountID: String,
        transport: HTTPTransport
    ) async -> (display: ProfileExpiryRefresh, catalog: [AccountCatalogItem]?, observedAt: Date?) {
        do {
            let result = try await AccountCatalogService(transport: transport).fetchCatalogEvidence()
            let observedAt = Date.now
            let catalog = result.displayItems
            let expiresAt = catalog.first(where: { $0.matchesAccountID(accountID) })?.expiresAt
                ?? catalog.first(where: { $0.isDefaultAccount })?.expiresAt
            return (.value(expiresAt), result.evidenceItems, observedAt)
        } catch {
            return (.unchanged, nil, nil)
        }
    }
}
