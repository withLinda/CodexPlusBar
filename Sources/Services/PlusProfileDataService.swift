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
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult
    func openChromeSignIn(for profile: PlusProfile) async throws
    func openChromePasskeySetup(for profile: PlusProfile) async throws
    func syncChromeSession(for profile: PlusProfile) async throws -> ChatGPTAuthContext
    func closeChromeSignIn(for profile: PlusProfile) async
    func clearSession(for profile: PlusProfile) async throws
    func removeProfileData(for profile: PlusProfile) async throws
}

@MainActor
final class PlusProfileDataService: PlusProfileDataServing {
    private let runtimeProvider: PlusProfileRuntimeProviding
    private let chromeSessionManager: ChromeSessionManaging

    init(
        runtimeProvider: PlusProfileRuntimeProviding = ProfileRuntimeRegistry(),
        chromeSessionManager: ChromeSessionManaging = DefaultChromeSessionManager()
    ) {
        self.runtimeProvider = runtimeProvider
        self.chromeSessionManager = chromeSessionManager
    }

    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
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
            expiryRefresh: expiryRefresh
        )
    }

    func clearSession(for profile: PlusProfile) async throws {
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        await runtimeProvider.clearSession(for: profile)
        try await chromeSessionManager.clearCookies(for: profile)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        try await runtimeProvider.removeProfileData(for: profile)
        try await chromeSessionManager.removeProfileData(for: profile)
    }

    func openChromeSignIn(for profile: PlusProfile) async throws {
        try await chromeSessionManager.openSignIn(for: profile)
    }

    func openChromePasskeySetup(for profile: PlusProfile) async throws {
        try await chromeSessionManager.openPasskeySetup(for: profile)
    }

    func syncChromeSession(for profile: PlusProfile) async throws -> ChatGPTAuthContext {
        let runtime = runtimeProvider.runtime(for: profile)
        _ = try await chromeSessionManager.syncCookies(
            for: profile,
            into: runtime.sessionStore
        )

        let authSessionService = AuthSessionService(
            transport: runtime.transport,
            sessionStore: runtime.sessionStore
        )

        do {
            let context = try await authSessionService.fetchCurrentSession(fallback: runtime.authContext)
            runtime.updateAuthContext(context)
            await chromeSessionManager.closeSignIn(for: profile)
            return context
        } catch {
            if ChatGPTAPIError.map(error) == .unauthorized {
                try? await chromeSessionManager.openSignIn(for: profile)
            }

            throw error
        }
    }

    func closeChromeSignIn(for profile: PlusProfile) async {
        await chromeSessionManager.closeSignIn(for: profile)
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
    ) async -> ProfileExpiryRefresh {
        do {
            let catalog = try await AccountCatalogService(transport: transport).fetchCatalog()
            let expiresAt = catalog.first(where: { $0.matchesAccountID(accountID) })?.expiresAt
                ?? catalog.first(where: { $0.isDefaultAccount })?.expiresAt
            return .value(expiresAt)
        } catch {
            return .unchanged
        }
    }
}
