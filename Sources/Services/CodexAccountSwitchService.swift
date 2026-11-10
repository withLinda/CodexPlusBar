import Foundation

protocol CodexAccountSwitchServing: CloudSavedSessionCapturing {
    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity
    func switchAndOpen(profile: PlusProfile) async throws
    func migrate(_ profiles: [PlusProfile]) -> ([PlusProfile], changed: Bool)
}

extension CodexAccountSwitchServing {
    func migrate(_ profiles: [PlusProfile]) -> ([PlusProfile], changed: Bool) { (profiles, false) }
}

/// Repair and switching may be owned by different service instances.
actor CodexOperationGate {
    static let shared = CodexOperationGate()
    private var busy: Set<URL> = []
    func withOperation<T: Sendable>(home: URL, _ operation: @Sendable () async throws -> T) async throws -> T {
        let key = home.resolvingSymlinksInPath()
        guard busy.insert(key).inserted else { throw CodexSignInError.busy }
        defer { busy.remove(key) }
        return try await operation()
    }
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
    let requiresNewSignIn: Bool

    init(cause: (any Error)?, recovery: Recovery, reopenFailed: Bool) {
        if let error = cause as? CodexSignInError { reason = error.localizedDescription }
        else if cause is CancellationError { reason = "The account switch was cancelled." }
        else if cause != nil { reason = "The desktop sign-in could not be switched." }
        else { reason = "" }
        self.recovery = recovery
        self.reopenFailed = reopenFailed
        requiresNewSignIn = (cause as? CodexSignInError)?.requiresNewSignIn == true
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
    private let operationGate: CodexOperationGate

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         app: any CodexDesktopAppManaging = CodexDesktopApp(),
         verifier: any CodexSignInVerifying = CodexSignInVerifier(),
         resolveStore: (@Sendable () throws -> CodexLiveAuthStore)? = nil,
         now: @escaping @Sendable () -> Date = { .now }, operationGate: CodexOperationGate = .shared) {
        self.homeDirectory = homeDirectory
        vault = CodexSignInVault(homeDirectory: homeDirectory)
        self.app = app
        self.verifier = verifier
        self.now = now
        self.operationGate = operationGate
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
        defer { CloudSavedSessionChange.released() }
        return try await operationGate.withOperation(home: homeDirectory) { try await self.saveCurrentUnlocked(for: profile) }
    }

    func captureSavedSession(for profile: PlusProfile) async throws -> CloudSessionPayload? {
        guard profile.provider == .codex, let identity = profile.codexSignIn else { return nil }
        return try await operationGate.withOperation(home: homeDirectory) { try await self.captureUnlocked(identity) }
    }

    private func captureUnlocked(_ identity: CodexSignInIdentity) throws -> CloudSessionPayload {
        guard !isWorking else { throw CodexSignInError.busy }
        return try vault.capture(identity)
    }

    private func saveCurrentUnlocked(for profile: PlusProfile) async throws -> CodexSignInIdentity {
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

    /// Repair the saved account without switching an unrelated live desktop account.
    func installCloudSession(_ received: CodexSignIn, for profile: PlusProfile, policy: CloudSessionInstallationPolicy,
                             authorization: CloudSessionAdoptionAuthorization) async throws -> CodexSignInIdentity {
        defer { CloudSavedSessionChange.released() }
        return try await operationGate.withOperation(home: homeDirectory) {
            try await self.installCloudSessionUnlocked(received, authorization: authorization)
        }
    }

    private func installCloudSessionUnlocked(_ received: CodexSignIn, authorization: CloudSessionAdoptionAuthorization) async throws -> CodexSignInIdentity {
        guard !isWorking else { throw CodexSignInError.busy }
        isWorking = true; defer { isWorking = false }
        try Task.checkCancellation()
        try await authorization.check()
        let vault = self.vault
        let receiptStore = try CloudSessionAdoptionReceiptStore(directory: vault.directory, key: authorization.receiptKey)
        let url = vault.url(for: received.identity)
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let receipt = try receiptStore.load()
        let target = try vault.latestGeneration(of: received)
        try await authorization.checkSource(.desktop(signIn: received, consumed: []),
            resolved: .desktop(signIn: target, consumed: []), receipt: receipt)
        if let receipt, !receipt.committed {
            let current = previous.map(CloudSessionAdoptionReceipt.fingerprint)
            guard current == receipt.previousFingerprint || current == receipt.targetFingerprint ||
                (receipt.recoveryStarted == true && target != received && previous == target.data) else { throw CloudSessionAdoptionError.changed }
        }
        let intent = CloudSessionAdoptionReceipt(sourceFingerprint: CloudSessionPayload.fingerprint(received.refreshToken),
            previousFingerprint: previous.map(CloudSessionAdoptionReceipt.fingerprint),
            targetFingerprint: CloudSessionAdoptionReceipt.fingerprint(target.data), nativeID: nil, committed: false, recoveryStarted: true)
        var local: CodexSignIn?
        do { local = try vault.load(received.identity) }
        catch CodexSignInError.missingSavedSignIn { }
        catch CodexSignInError.invalidCredential { }
        if let local {
            do {
                if receipt == nil, local.refreshToken == received.refreshToken {
                    try await authorization.write { try receiptStore.save(intent) }
                }
                let prepared = try await prepareCloud(local, authorization: authorization)
                try Task.checkCancellation()
                try await authorization.write {
                    try authorization.check(.desktop(signIn: prepared, consumed: []))
                    try authorization.completed(prepared.identity, .desktop, receipt != nil)
                }
                return prepared.identity
            } catch CodexSignInError.unauthorized { /* Confirmed rejected; remote may repair. */ }
        }
        if receipt == nil { try await authorization.write { try receiptStore.save(intent) } }
        let prepared = try await prepareCloud(target, authorization: authorization)
        try Task.checkCancellation()
        // Refresh recovery may already have replaced the saved snapshot. Compare
        // the resolved generation too; no live store is opened by this policy.
        return try await authorization.write {
            try authorization.check(.desktop(signIn: prepared, consumed: []))
            let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard current == previous || current == prepared.data else { throw CloudSessionAdoptionError.changed }
            var receipt = CloudSessionAdoptionReceipt(sourceFingerprint: CloudSessionPayload.fingerprint(received.refreshToken),
                previousFingerprint: current.map(CloudSessionAdoptionReceipt.fingerprint),
                targetFingerprint: CloudSessionAdoptionReceipt.fingerprint(prepared.data), nativeID: nil, committed: false, recoveryStarted: true)
            try receiptStore.save(receipt)
            try vault.save(prepared)
            receipt.committed = true
            try receiptStore.save(receipt)
            try authorization.completed(prepared.identity, .desktop, true)
            return prepared.identity
        }
    }

    private func prepareCloud(_ signIn: CodexSignIn, authorization: CloudSessionAdoptionAuthorization) async throws -> CodexSignIn {
        try await authorization.check(.desktop(signIn: signIn, consumed: []))
        return try await prepare(signIn, beforeRefresh: {
            try await authorization.check(.desktop(signIn: signIn, consumed: []))
        }, beforeVerification: { candidate in
            try await authorization.check(.desktop(signIn: candidate, consumed: []))
        }) { fresh in
            // A consumed pair is recovery, not installation permission. Persist
            // before cancellation, cloud admission checks or further network work.
            try self.vault.saveRefreshed(fresh, replacing: signIn)
        }
    }

    func installRepaired(_ received: CodexSignIn, for profile: PlusProfile) async throws {
        defer { CloudSavedSessionChange.released() }
        try await operationGate.withOperation(home: homeDirectory) { try await self.installRepairedUnlocked(received, for: profile) }
    }

    private func installRepairedUnlocked(_ received: CodexSignIn, for profile: PlusProfile) async throws {
        guard !isWorking else { throw CodexSignInError.busy }
        isWorking = true; defer { isWorking = false }
        try received.validateRepair(for: profile)
        try await app.validateConfiguration()
        let store = try resolveStore()
        let original = try store.read()
        let active = try original.map { try CodexSignIn(data: $0) }
        let selected = active == nil || active?.identity.matches(received.identity) == true
        let installed = vault.hasRepairReceipt(for: received)
        let installedLive = try vault.repairWasInstalledLive(received, current: original)
        var signIn = try vault.latestGeneration(of: received)
        if installed {
            // Once this grant has been installed, the destination can rotate it
            // independently. A pending browser grant is no longer authoritative.
            let current = try selected && installedLive
                ? active.map { try vault.latestGeneration(of: $0) } : vault.load(received.identity)
            if let current, current != signIn {
                try current.validateRepair(for: profile)
                try vault.saveRefreshed(current, replacing: signIn)
                signIn = current
            }
        }
        try store.validate(signIn)
        try Task.checkCancellation()
        if selected {
            do { try await app.close() }
            catch CodexDesktopCloseError.terminationStarted {
                _ = await reopen(); throw CodexSignInError.appCouldNotClose
            }
        }
        do {
            try Task.checkCancellation()
            guard try store.read() == original else { throw CodexSignInError.concurrentChange }
            var expected = original
            let repairingInstalledPair = installedLive || original == signIn.data
            if selected, repairingInstalledPair, original != signIn.data {
                try store.replace(with: signIn.data, expected: expected)
                expected = signIn.data
            }
            let prepared = try await prepare(signIn) { fresh in
                try self.vault.saveRefreshed(fresh, replacing: signIn)
                // Settle consumed-token replacement before cancellation or a
                // fallible usage verification can leave the app on the old pair.
                if selected, repairingInstalledPair {
                    try store.replace(with: fresh.data, expected: expected)
                    expected = fresh.data
                }
            }
            try vault.save(prepared)
            try Task.checkCancellation()
            if selected {
                // Journal before committing: a lost receipt write or process exit
                // must not make a later native rotation look like an old grant.
                try vault.saveRepairIntent(for: received, previous: expected, target: prepared.data)
                try store.replace(with: prepared.data, expected: expected)
            }
            try vault.saveRepairReceipt(for: received, live: selected)
        } catch {
            if selected { _ = await reopen() }
            throw error
        }
        if selected, !(await reopen()) { throw CodexSignInError.reopenFailed }
    }

    func switchAndOpen(profile: PlusProfile) async throws {
        defer { CloudSavedSessionChange.released() }
        try await operationGate.withOperation(home: homeDirectory) { try await self.switchAndOpenUnlocked(profile: profile) }
    }

    private func switchAndOpenUnlocked(profile: PlusProfile) async throws {
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
                         beforeRefresh: () async throws -> Void = {},
                         beforeVerification: (CodexSignIn) async throws -> Void = { _ in },
                         didRefresh: (CodexSignIn) throws -> Void) async throws -> CodexSignIn {
        if !signIn.needsRefresh(at: now()) {
            try await beforeVerification(signIn)
            do { try await verifier.verify(signIn); return signIn }
            catch CodexSignInError.unauthorized { /* Refresh exactly once. */ }
        }
        try Task.checkCancellation()
        try await beforeRefresh()
        let refreshed = try await verifier.refresh(signIn)
        guard signIn.identity.matches(refreshed.identity) else { throw CodexSignInError.identityMismatch }
        try didRefresh(refreshed)
        try Task.checkCancellation()
        try await beforeVerification(refreshed)
        try await verifier.verify(refreshed)
        return refreshed
    }
}
