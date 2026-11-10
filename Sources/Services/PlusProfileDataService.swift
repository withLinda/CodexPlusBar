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
    func adoptBrowserSession(_ payload: CloudSessionPayload, for profile: PlusProfile, authorization: CloudSessionAdoptionAuthorization) async throws
}

extension PlusProfileDataServing {
    func openAppAuthorization(_ url: URL, for profile: PlusProfile) async throws { throw AppSignInRepairError.helperUnavailable }
    func captureSavedSession(for profile: PlusProfile) async throws -> CloudSessionPayload? { nil }
    func adoptBrowserSession(_ payload: CloudSessionPayload, for profile: PlusProfile, authorization: CloudSessionAdoptionAuthorization) async throws { throw CloudSessionError.unavailable }
}

@MainActor
final class PlusProfileDataService: PlusProfileDataServing {
    private let runtimeProvider: PlusProfileRuntimeProviding
    private let chromeSessionManager: ChromeSessionManaging
    private var operating: Set<UUID> = []
    private var browserProof: [UUID: (store: UUID, payload: CloudSessionPayload)] = [:]
    private let browserAdoption: CloudBrowserSessionAdoption?
    private let browserSeeds: CloudBrowserSeedStore

    init(
        runtimeProvider: PlusProfileRuntimeProviding = ProfileRuntimeRegistry(),
        chromeSessionManager: ChromeSessionManaging = DefaultChromeSessionManager(),
        browserAdoption: CloudBrowserSessionAdoption? = nil, browserSeeds: CloudBrowserSeedStore = .init()
    ) {
        self.runtimeProvider = runtimeProvider
        self.chromeSessionManager = chromeSessionManager
        self.browserAdoption = browserAdoption ?? (runtimeProvider as? ProfileRuntimeRegistry).map { .init(registry: $0) }
        self.browserSeeds = browserSeeds
    }

    func adoptBrowserSession(_ payload: CloudSessionPayload, for profile: PlusProfile, authorization: CloudSessionAdoptionAuthorization) async throws {
        guard profile.id == authorization.request.profileID, let browserAdoption, operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id); CloudSavedSessionChange.released() }
        var staged: PlusProfile?
        var catalogAttempted = false
        do {
            try authorization.check(payload)
            let fresh = try await browserAdoption.prepare(payload, for: profile) { try authorization.check(payload) }
            staged = fresh
            let verified = try await browserAdoption.preparedPayload(profileID: profile.id)
            try Task.checkCancellation()
            try authorization.write {
                let remote = fresh.webDataStoreID != profile.webDataStoreID
                if remote { try browserSeeds.save(verified, for: fresh) }
                catalogAttempted = true
                try authorization.browserCompleted(fresh, remote)
                try browserAdoption.commit(profileID: profile.id)
                browserProof[profile.id] = (fresh.webDataStoreID, verified)
                CloudSavedSessionChange.committed()
                if remote { try? browserSeeds.remove(for: profile) }
            }
        } catch {
            if let staged, staged.webDataStoreID != profile.webDataStoreID {
                // A save can rename before reporting an error. Never destroy the
                // recovery body for a visible or uncertain catalog commit.
                let committed = catalogAttempted ? (try? authorization.browserCommitStatus(staged)) : false
                if committed == false { try? browserSeeds.remove(for: staged) }
            }
            await browserAdoption.discard(profileID: profile.id)
            throw error
        }
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
        try await restoreBrowserIfNeeded(profile, runtime: runtime)
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
        try browserSeeds.remove(for: profile)
        browserProof.removeValue(forKey: profile.id)
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        await runtimeProvider.clearSession(for: profile)
        try await chromeSessionManager.clearCookies(for: profile)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id) }
        try browserSeeds.remove(for: profile)
        browserProof.removeValue(forKey: profile.id)
        let runtime = runtimeProvider.runtime(for: profile)
        runtime.updateAuthContext(nil)
        try await runtimeProvider.removeProfileData(for: profile)
        try await chromeSessionManager.removeProfileData(for: profile)
    }

    func openChromeSignIn(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id) }
        // Explicit Sign in starts a new local authorization. A queued imported
        // snapshot must never overwrite that newer session on a later open.
        try browserSeeds.remove(for: profile)
        try await chromeSessionManager.openSignIn(for: profile)
    }

    func openChromeAccountPage(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id) }
        try await seedPendingBrowser(profile)
        try await chromeSessionManager.openAccountPage(for: profile)
    }

    func openChromePasskeySetup(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id) }
        try await seedPendingBrowser(profile)
        try await chromeSessionManager.openPasskeySetup(for: profile)
    }

    private func seedPendingBrowser(_ profile: PlusProfile) async throws {
        try await restoreBrowserIfNeeded(profile, runtime: runtimeProvider.runtime(for: profile))
        guard let pending = try browserSeeds.load(for: profile), case .browser(let cookies, _, _) = pending.payload else { return }
        guard pending.chromeSeedPending else { return }
        try await chromeSessionManager.seedCookies(cookies, for: profile)
        try browserSeeds.save(pending.payload, for: profile, chromeSeedPending: false)
    }

    private func restoreBrowserIfNeeded(_ profile: PlusProfile, runtime: PlusProfileRuntime) async throws {
        guard let saved = try browserSeeds.load(for: profile), case .browser(let cookies, _, _) = saved.payload else { return }
        let current = await runtime.sessionStore.portableChatGPTCookies()
        let valid = cookies.filter { $0.expires.map { $0 > .now } ?? true }
        // A newer local cookie always wins. An empty/restarted store or an exact
        // surviving persistent subset can recover the saved session-only values.
        func normalized(_ cookie: BackupCookie) -> BackupCookie {
            var value = cookie
            value.sameSite = value.sameSite?.lowercased()
            value.expires = value.expires.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
            return value
        }
        let known = valid.map(normalized), observed = current.map(normalized)
        guard observed.allSatisfy({ known.contains($0) }) else {
            try browserSeeds.remove(for: profile)
            return
        }
        let missing = valid.filter { !observed.contains(normalized($0)) }
        await runtime.sessionStore.storeCookies(missing.compactMap(\.cookie))
    }

    func syncChromeSession(for profile: PlusProfile) async throws {
        guard operating.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { operating.remove(profile.id); CloudSavedSessionChange.committed(); CloudSavedSessionChange.released() }
        try browserSeeds.remove(for: profile)
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
        // Replace recovery with the newly verified local generation. Never leave
        // an older queued Chrome seed behind a newer authenticated WebKit login.
        if let saved = try? browserSeeds.load(for: profile) {
            do { try browserSeeds.save(validated, for: profile, chromeSeedPending: saved.chromeSeedPending && saved.payload == validated) }
            catch { try? browserSeeds.remove(for: profile) }
        }
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
