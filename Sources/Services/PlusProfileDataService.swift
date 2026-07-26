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
    func openChromeAccountPage(for profile: PlusProfile) async throws
    func openChromeSignIn(for profile: PlusProfile) async throws
    func openChromePasskeySetup(for profile: PlusProfile) async throws
    func syncChromeSession(for profile: PlusProfile) async throws
    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool
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
        switch profile.provider {
        case .codex:
            return try await refreshCodexProfile(profile)
        case .claude:
            return try await refreshClaudeProfile(profile)
        }
    }

    private func refreshCodexProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
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

    private func refreshClaudeProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        let snapshot: WorkspaceLimitSnapshot

        do {
            snapshot = try await fetchClaudeSnapshot(using: runtime)
        } catch let originalError as ChatGPTAPIError where originalError == .unauthorized {
            do {
                _ = try await chromeSessionManager.restoreCookies(
                    for: profile,
                    into: runtime.sessionStore
                )
                runtime.updateClaudeOrganizationID(nil)
                snapshot = try await fetchClaudeSnapshot(using: runtime)
            } catch let restoreError as ChatGPTAPIError where restoreError == .unauthorized {
                throw originalError
            }
        }

        return PlusProfileRefreshResult(
            usage: PlusProfileUsage(
                accountID: snapshot.accountID,
                planType: snapshot.planType,
                primaryWindow: snapshot.primaryWindow,
                secondaryWindow: snapshot.secondaryWindow,
                fetchedAt: snapshot.fetchedAt
            ),
            detectedNote: "Claude",
            expiryRefresh: .unchanged
        )
    }

    func clearSession(for profile: PlusProfile) async throws {
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        runtime.updateClaudeOrganizationID(nil)
        await runtimeProvider.clearSession(for: profile)
        try await chromeSessionManager.clearCookies(for: profile)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        runtime.updateClaudeOrganizationID(nil)
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
        let runtime = runtimeProvider.runtime(for: profile)
        _ = try await chromeSessionManager.syncCookies(
            for: profile,
            into: runtime.sessionStore
        )

        do {
            switch profile.provider {
            case .codex:
                let authSessionService = AuthSessionService(
                    transport: runtime.transport,
                    sessionStore: runtime.sessionStore
                )
                let context = try await authSessionService.fetchCurrentSession(
                    fallback: runtime.authContext
                )
                runtime.updateAuthContext(context)
            case .claude:
                runtime.updateAuthContext(nil)
                runtime.updateClaudeOrganizationID(nil)
                _ = try await fetchClaudeSnapshot(using: runtime)
            }

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

    private static func makeUsageRequest(accountID: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        return request
    }

    private func fetchClaudeSnapshot(
        using runtime: PlusProfileRuntime
    ) async throws -> WorkspaceLimitSnapshot {
        if let cachedOrganizationID = runtime.claudeOrganizationID {
            do {
                return try await fetchClaudeSnapshot(
                    organizationID: cachedOrganizationID,
                    transport: runtime.transport
                )
            } catch let error as ChatGPTAPIError where error == .httpStatus(404) {
                runtime.updateClaudeOrganizationID(nil)
            }
        }

        let preferredOrganizationID = await runtime.sessionStore.cookieValue(
            named: ClaudeBootstrapService.lastActiveOrganizationCookieName,
            for: ClaudeWebURLs.cookieScope
        )
        let organizationIDs = try await ClaudeBootstrapService(
            transport: runtime.transport
        ).fetchOrganizationIDs(
            preferredOrganizationID: preferredOrganizationID
        )

        var lastNotFoundError: ChatGPTAPIError?

        for organizationID in organizationIDs {
            do {
                let snapshot = try await fetchClaudeSnapshot(
                    organizationID: organizationID,
                    transport: runtime.transport
                )
                runtime.updateClaudeOrganizationID(organizationID)
                return snapshot
            } catch let error as ChatGPTAPIError where error == .httpStatus(404) {
                lastNotFoundError = error
            }
        }

        throw lastNotFoundError
            ?? ChatGPTAPIError.unsupported(
                "Claude did not provide usage for any organization in this profile."
            )
    }

    private func fetchClaudeSnapshot(
        organizationID: String,
        transport: HTTPTransport
    ) async throws -> WorkspaceLimitSnapshot {
        let request = try ClaudeUsageService.makeUsageRequest(
            organizationID: organizationID
        )
        let response = try await transport.data(for: request)
        return try ClaudeUsageService.decodeSnapshot(
            from: response.data,
            organizationID: organizationID
        )
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
