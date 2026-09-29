import Foundation

protocol CodexAccountSwitchServing: Sendable {
    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity
    func switchAndOpen(profile: PlusProfile) async throws
    func migrate(_ profiles: [PlusProfile]) -> ([PlusProfile], changed: Bool)
}

extension CodexAccountSwitchServing {
    func migrate(_ profiles: [PlusProfile]) -> ([PlusProfile], changed: Bool) { (profiles, false) }
}

struct CodexSignInSwitchError: LocalizedError {
    enum Recovery: Equatable {
        case unchanged, restored, refreshedCurrent, changedExternally, restoreFailed, selected
        var message: String {
            switch self {
            case .unchanged: "The previous desktop sign-in was kept."
            case .restored: "The previous desktop sign-in was restored."
            case .refreshedCurrent: "The current account’s refreshed sign-in was kept."
            case .changedExternally: "Another app’s sign-in changes were kept."
            case .restoreFailed: "Check the active account in the desktop app."
            case .selected: "The selected sign-in was installed and verified."
            }
        }
    }
    let reason: String
    let recovery: Recovery
    let reopenFailed: Bool

    init(cause: (any Error)?, recovery: Recovery, reopenFailed: Bool) {
        if let error = cause as? CodexSignInError { reason = error.localizedDescription }
        else if cause is CancellationError { reason = "The account switch was cancelled." }
        else if cause != nil { reason = "The desktop sign-in could not be switched." }
        else { reason = "" }
        self.recovery = recovery
        self.reopenFailed = reopenFailed
    }

    var errorDescription: String? {
        [reason, recovery.message, reopenFailed ? CodexSignInError.reopenFailed.localizedDescription : ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Serializes desktop actions across actor reentrancy. AppKit is isolated in the lifecycle adapter.
actor CodexAccountSwitchService: CodexAccountSwitchServing {
    nonisolated let homeDirectory: URL
    private let vault: CodexSignInVault
    private let app: any CodexDesktopAppManaging
    private let verifier: any CodexSignInVerifying
    private let resolveStore: @Sendable () throws -> CodexLiveAuthStore
    private let now: @Sendable () -> Date
    private var isWorking = false

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         app: any CodexDesktopAppManaging = CodexDesktopApp(),
         verifier: any CodexSignInVerifying = CodexSignInVerifier(),
         resolveStore: (@Sendable () throws -> CodexLiveAuthStore)? = nil,
         now: @escaping @Sendable () -> Date = { .now }) {
        self.homeDirectory = homeDirectory
        vault = CodexSignInVault(homeDirectory: homeDirectory)
        self.app = app
        self.verifier = verifier
        self.now = now
        self.resolveStore = resolveStore ?? {
            let environment = ProcessInfo.processInfo.environment
            // A GUI switch must target the desktop's standard store, not this process's overrides.
            let unsupported = ["CODEX_HOME", "CODEX_AUTH_JSON", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY",
                               "CODEX_REFRESH_TOKEN_URL_OVERRIDE", "CODEX_APP_SERVER_LOGIN_CLIENT_ID"]
            guard !unsupported.contains(where: { environment[$0]?.isEmpty == false }) else {
                throw CodexSignInError.unsupportedConfiguration
            }
            return try CodexLiveAuthStore(codexHome: homeDirectory.appendingPathComponent(".codex"))
        }
    }

    nonisolated func migrate(_ profiles: [PlusProfile]) -> ([PlusProfile], changed: Bool) {
        CodexLegacySignInImporter(homeDirectory: homeDirectory).migrate(profiles)
    }

    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity {
        guard !isWorking else { throw CodexSignInError.busy }
        isWorking = true
        defer { isWorking = false }
        try Task.checkCancellation()
        try await app.validateConfiguration()
        let store = try resolveStore()
        guard let data = try store.read() else { throw CodexSignInError.missingCredential }
        let signIn = try vault.latestGeneration(of: CodexSignIn(data: data))
        try signIn.validate(for: profileWithLegacyIdentity(profile))
        try store.validate(signIn)
        guard try store.read() == data else { throw CodexSignInError.concurrentChange }
        try vault.save(signIn)
        return signIn.identity
    }

    func switchAndOpen(profile: PlusProfile) async throws {
        guard !isWorking else { throw CodexSignInError.busy }
        isWorking = true
        defer { isWorking = false }
        try Task.checkCancellation()
        guard let identity = profile.codexSignIn else { throw CodexSignInError.missingSavedSignIn }
        let saved = try vault.load(identity)
        try saved.validate(for: profile)
        let store = try resolveStore()
        try store.validate(saved)
        _ = try store.read() // Resolve access/configuration errors before closing the desktop app.
        do { try await app.close() }
        catch CodexDesktopCloseError.terminationStarted {
            let reopened = await reopen()
            throw CodexSignInSwitchError(cause: CodexSignInError.appCouldNotClose, recovery: .unchanged, reopenFailed: !reopened)
        }

        var original: Data?
        var expected: Data?
        var installed: Data?
        var recovery: CodexSignInSwitchError.Recovery = .unchanged
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            original = try store.read()
            expected = original
            let parsedOutgoing = original.flatMap { try? CodexSignIn(data: $0) }
            let outgoing = try parsedOutgoing.map { try vault.latestGeneration(of: $0) }
            if let outgoing { try vault.save(outgoing) }
            let sameAccount = outgoing.map { identity.matches($0.identity) } ?? false
            let target = sameAccount ? outgoing! : saved
            // A prior failed installation can leave a known-consumed token in the live store.
            // Repair it before verification; never roll back to that consumed generation.
            if let outgoing, outgoing.data != original {
                try store.replace(with: outgoing.data, expected: expected)
                original = outgoing.data
                expected = outgoing.data
                recovery = .refreshedCurrent
            }
            let prepared = try await prepare(target) { refreshed in
                // Refresh consumes the previous token. Save before cancellation or further network work.
                try self.vault.saveRefreshed(refreshed, replacing: target)
                if sameAccount {
                    try store.replace(with: refreshed.data, expected: expected)
                    expected = refreshed.data
                    recovery = .refreshedCurrent
                }
            }
            try Task.checkCancellation()
            guard try store.read() == expected else { throw CodexSignInError.concurrentChange }
            if !sameAccount {
                // Record the attempted write before calling replace: readback can fail after commit.
                installed = prepared.data
                try store.replace(with: prepared.data, expected: expected)
                try await verifier.verify(prepared)
                try Task.checkCancellation()
                guard try store.read() == prepared.data else { throw CodexSignInError.concurrentChange }
            }
            recovery = .selected
        } catch {
            failure = error
            if let installed {
                do {
                    let current = try store.read()
                    if current == installed {
                        if let original {
                            try store.replace(with: original, expected: installed)
                        } else {
                            try store.remove(expected: installed)
                        }
                        recovery = .restored
                    } else if current != original {
                        recovery = .changedExternally
                    }
                } catch { recovery = .restoreFailed }
            } else if expected != nil, (try? store.read()) != expected {
                recovery = .changedExternally
            }
        }

        // Reopening must survive cancellation of the original task after the app has closed.
        let reopened = await reopen()
        if failure != nil || !reopened {
            throw CodexSignInSwitchError(cause: failure, recovery: recovery, reopenFailed: !reopened)
        }
    }

    private func reopen() async -> Bool {
        let app = self.app
        return await Task.detached { () -> Bool in
            do { try await app.open(); return true } catch { return false }
        }.value
    }

    private func profileWithLegacyIdentity(_ profile: PlusProfile) throws -> PlusProfile {
        guard profile.codexSignIn == nil, profile.codexAccountKey != nil else { return profile }
        let account = try CodexLegacySignInImporter(homeDirectory: homeDirectory).linkedAccount(for: profile)
        if let existing = profile.openCodeOpenAIAccount,
           existing.accountID != account.chatgptAccountID || existing.userID != account.chatgptUserID {
            throw CodexSignInError.identityMismatch
        }
        var linked = profile
        linked.codexSignIn = .init(accountID: account.chatgptAccountID, userID: account.chatgptUserID, email: account.email)
        return linked
    }

    private func prepare(_ signIn: CodexSignIn,
                         didRefresh: (CodexSignIn) throws -> Void) async throws -> CodexSignIn {
        if !signIn.needsRefresh(at: now()) {
            do { try await verifier.verify(signIn); return signIn }
            catch CodexSignInError.unauthorized { /* Refresh exactly once. */ }
        }
        try Task.checkCancellation()
        let refreshed = try await verifier.refresh(signIn)
        guard signIn.identity.matches(refreshed.identity) else { throw CodexSignInError.identityMismatch }
        try didRefresh(refreshed)
        try Task.checkCancellation()
        try await verifier.verify(refreshed)
        return refreshed
    }
}
