import Foundation
import WebKit

@MainActor final class CloudBrowserSessionAdoption {
    typealias Verify = @MainActor (PlusProfileRuntime) async throws -> ChatGPTAuthContext
    private struct Staged {
        let profile: PlusProfile
        let runtime: PlusProfileRuntime
        var replacesStore = true
    }
    private let registry: ProfileRuntimeRegistry
    private let verify: Verify
    private var staged: [UUID: Staged] = [:]
    private var preparing: Set<UUID> = []
    init(registry: ProfileRuntimeRegistry, verify: @escaping Verify = { runtime in
        try await AuthSessionService(transport: runtime.transport, sessionStore: runtime.sessionStore).fetchCurrentSession()
    }) { self.registry = registry; self.verify = verify }

    func prepare(_ payload: CloudSessionPayload, for profile: PlusProfile,
                 validate: @MainActor () throws -> Void = {}) async throws -> PlusProfile {
        guard profile.provider == .codex, staged[profile.id] == nil, preparing.insert(profile.id).inserted else { throw CloudSessionError.unavailable }
        defer { preparing.remove(profile.id) }
        guard case .browser(let cookies, let expected, _) = try payload.validated() else { throw CloudSessionError.invalidPayload }
        try expected.validateBindings(of: profile)
        let old = registry.runtime(for: profile)
        let existing = await old.sessionStore.portableChatGPTCookies()
        try validate()
        if existing.contains(where: { $0.name == "__Secure-next-auth.session-token" || $0.name.hasPrefix("__Secure-next-auth.session-token.") }) {
            do {
                let context = try await verify(old)
                try validate()
                guard context.accountID == expected.accountID, context.userID == expected.userID else { throw CloudSessionError.identityMismatch }
                try Task.checkCancellation()
                old.updateAuthContext(context)
                staged[profile.id] = .init(profile: profile, runtime: old, replacesStore: false)
                return profile
            } catch ChatGPTAPIError.unauthorized { }
        }
        let valid = cookies.filter { $0.expires.map { $0 > .now } ?? true }
        guard valid.contains(where: { $0.name == "__Secure-next-auth.session-token" || $0.name.hasPrefix("__Secure-next-auth.session-token.") }) else { throw CloudSessionError.unavailable }
        try Task.checkCancellation()
        try validate()
        let fresh = profile.reidentified(profile.id, webDataStoreID: UUID())
        let runtime = PlusProfileRuntime(dataStore: WKWebsiteDataStore(forIdentifier: fresh.webDataStoreID))
        do {
            await runtime.sessionStore.storeCookies(valid.compactMap(\.cookie))
            try Task.checkCancellation()
            try validate()
            let context = try await verify(runtime)
            try validate()
            guard context.accountID == expected.accountID, context.userID == expected.userID else { throw CloudSessionError.identityMismatch }
            try Task.checkCancellation()
            runtime.updateAuthContext(context)
            staged[profile.id] = .init(profile: fresh, runtime: runtime)
            return fresh
        } catch {
            await runtime.sessionStore.clear()
            try? await DefaultProfileDataStoreManager().removeDataStore(for: fresh.webDataStoreID)
            throw error
        }
    }
    func commit(profileID: UUID) throws {
        guard let value = staged.removeValue(forKey: profileID) else { throw CloudSessionError.unavailable }
        registry.adopt(value.runtime, for: value.profile)
    }
    func preparedPayload(profileID: UUID) async throws -> CloudSessionPayload {
        guard let value = staged[profileID], let context = value.runtime.authContext, let user = context.userID else { throw CloudSessionError.unavailable }
        let cookies = await value.runtime.sessionStore.portableChatGPTCookies()
        return try CloudSessionPayload.browser(cookies: cookies, identity: .init(accountID: context.accountID, userID: user), accessToken: context.accessToken).validated()
    }
    func discard(profileID: UUID) async {
        guard let value = staged.removeValue(forKey: profileID) else { return }
        guard value.replacesStore else { return }
        await value.runtime.sessionStore.clear()
        try? await DefaultProfileDataStoreManager().removeDataStore(for: value.profile.webDataStoreID)
    }
}
