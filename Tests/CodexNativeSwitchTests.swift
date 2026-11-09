import AppKit
import Foundation
import Testing
@testable import CodexPlusBar

struct CodexNativeSwitchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_DESKTOP_RUNTIME_PROBE"] == "1"))
    @MainActor
    func installedDesktopSignInCanBeSavedToAnIsolatedVault() async throws {
        // Opt-in: read the real desktop configuration and sign-in, but only write a temporary
        // private vault. Never close the desktop, refresh tokens, or change its live storage.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: CodexDesktopApp.bundleIdentifier)
        let appURL = try #require(running.first?.bundleURL, "Launch ChatGPT / Codex before enabling this runtime probe")
        #expect(CodexDesktopApp.hasBundledProcesses(appURL))
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let store = try CodexLiveAuthStore(codexHome: codexHome)
        let current = try store.read()
        let original = try #require(current)
        let signIn = try CodexSignIn(data: original)
        var profile = CodexSignInFixture.profile()
        profile.label = signIn.identity.email
        let service = CodexAccountSwitchService(homeDirectory: home, resolveStore: { store })

        let saved = try await service.saveCurrent(for: profile)

        // Compare Booleans so a failed assertion cannot print credentials or account identity.
        let identityMatches = saved == signIn.identity
        let snapshotMatches = try CodexSignInVault(homeDirectory: home).load(saved).data == original
        let liveUnchanged = try store.read() == original
        #expect(identityMatches)
        #expect(snapshotMatches)
        #expect(liveUnchanged)
    }

    @Test(arguments: [
        ["-c", "forced_login_method=\"chatgpt\""],
        ["--config", "forced_login_method = 'chatgpt'"],
        ["--config=forced_login_method=\"chatgpt\""],
        ["-cforced_login_method=chatgpt"]
    ])
    func desktopChatGPTLoginRestrictionAllowsSavingCurrentSignIn(overrides: [String]) async throws {
        let fixture = try NativeSwitchFixture()
        defer { fixture.cleanUp() }
        let original = try CodexSignInFixture.data()
        try original.write(to: fixture.authURL)
        let home = fixture.home.appendingPathComponent(".codex")
        let app = ConfiguredNativeApp(arguments: ["codex"] + overrides + ["exec-server", "--remote", "https://example.com", "--environment-id", "synthetic"])
        let service = CodexAccountSwitchService(
            homeDirectory: fixture.home, app: app,
            resolveStore: { try CodexLiveAuthStore(codexHome: home, keychain: MemoryCodexKeychain()) }
        )

        let identity = try await service.saveCurrent(for: fixture.profile)

        #expect(try fixture.vault.load(identity).data == original)
        #expect(try Data(contentsOf: fixture.authURL) == original)
        var linked = fixture.profile; linked.codexSignIn = identity
        let captured = try #require(try await service.captureSavedSession(for: linked))
        if case .desktop(let signIn, _) = captured { #expect(signIn.data == original) }
        else { Issue.record("Expected saved desktop snapshot") }
    }

    @Test(arguments: [
        ["-c", "forced_login_method='api'"],
        ["-c", "forced_login_method='unknown'"],
        ["-c", "forced_login_method=\"chatgpt\" extra"],
        ["-c", "nested.forced_login_method='chatgpt'"],
        ["--enable", "forced_login_method=chatgpt"],
        ["forced_login_method=chatgpt"],
        ["-c", "forced_login_method='chatgpt'", "-c", "forced_login_method='api'"],
        ["-c", "forced_login_method='api'", "-c", "forced_login_method='chatgpt'"],
        ["-c", "forced_login_method='chatgpt'", "-c", "cli_auth_credentials_store='keyring'"],
        ["-c", "forced_login_method='chatgpt'", "-c", "forced_chatgpt_workspace_id='other'"],
        ["-c", "forced_login_method='chatgpt'", "--enable", "secret_auth_storage"],
        ["-c", "forced_login_method='chatgpt'", "-c", "chatgpt_base_url='https://example.com'"]
    ])
    func compatibleLoginFlagDoesNotBypassUnsupportedOverrides(overrides: [String]) throws {
        #expect(throws: CodexSignInError.unsupportedConfiguration) {
            try CodexDesktopApp.validateProcess(arguments: ["codex"] + overrides, environment: [:],
                                               standardHome: URL(fileURLWithPath: "/Users/sample/.codex"))
        }
    }

    @Test func compatibleLoginFlagDoesNotBypassEnvironmentOverrides() throws {
        let home = URL(fileURLWithPath: "/Users/sample/.codex")
        for key in ["CODEX_HOME", "CODEX_AUTH_JSON", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY",
                    "CODEX_REFRESH_TOKEN_URL_OVERRIDE", "CODEX_APP_SERVER_LOGIN_CLIENT_ID"] {
            #expect(throws: CodexSignInError.unsupportedConfiguration) {
                try CodexDesktopApp.validateProcess(arguments: ["codex", "-c", "forced_login_method=\"chatgpt\""],
                                                   environment: [key: "/other"], standardHome: home)
            }
        }
    }

    @Test func runtimeAuthOverridesAreRejectedBeforeUsingStandardStorage() throws {
        let home = URL(fileURLWithPath: "/Users/sample/.codex")
        #expect(throws: CodexSignInError.unsupportedConfiguration) {
            try CodexDesktopApp.validateProcess(arguments: ["codex", "app-server", "-c", "cli_auth_credentials_store='keyring'"], environment: [:], standardHome: home)
        }
        #expect(throws: CodexSignInError.unsupportedConfiguration) {
            try CodexDesktopApp.validateProcess(arguments: ["codex", "--enable", "secret_auth_storage"], environment: [:], standardHome: home)
        }
        #expect(throws: CodexSignInError.unsupportedConfiguration) {
            try CodexDesktopApp.validateProcess(arguments: ["codex"], environment: ["CODEX_HOME": "/other"], standardHome: home)
        }
        try CodexDesktopApp.validateProcess(arguments: ["codex", "app-server", "--listen", "stdio://"], environment: ["CODEX_HOME": home.path], standardHome: home)
    }

    @Test func actualTaskCancellationAfterRefreshPreservesTokensBeforeReopening() async throws {
        for sameAccount in [false, true] {
            let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "rotated"))
            let verifier = PendingNativeRefresh(fresh: fresh)
            let fixture = try NativeSwitchFixture(verifier: verifier)
            defer { fixture.cleanUp() }
            let profile = try fixture.installTarget(expired: true)
            if sameAccount { try fixture.vault.load(fresh.identity).data.write(to: fixture.authURL) }
            let original = try Data(contentsOf: fixture.authURL)
            let task = Task { try await fixture.service.switchAndOpen(profile: profile) }
            await verifier.waitForStart()
            // Another instance (repair owns one) must share the same home gate.
            let exporter = CodexAccountSwitchService(homeDirectory: fixture.home,
                resolveStore: { throw CodexSignInError.unsupportedConfiguration })
            await #expect(throws: CodexSignInError.busy) { try await exporter.captureSavedSession(for: profile) }
            task.cancel()
            await verifier.finish()
            await #expect(throws: CodexSignInSwitchError.self) { try await task.value }
            #expect(try fixture.vault.load(fresh.identity).refreshToken == "rotated")
            #expect(try Data(contentsOf: fixture.authURL) == (sameAccount ? fresh.data : original))
            #expect(await verifier.returnedWhileCancelled)
            #expect(await fixture.app.events == ["close", "open"])
            let captured = try #require(try await exporter.captureSavedSession(for: profile))
            if case .desktop(let signIn, let consumed) = captured {
                #expect(signIn == fresh)
                #expect(!consumed.isEmpty)
            } else { Issue.record("Expected resolved desktop snapshot") }
        }
    }

    @Test func retryAfterFailedRotationInstallUsesPreservedTokens() async throws {
        let home = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "rotated"))
        let verifier = NativeVerifierStub(refreshed: fresh, afterRefresh: {
            try Data("# Settings changed during the refresh request".utf8).write(to: config)
        })
        let fixture = try NativeSwitchFixture(home: home, verifier: verifier)
        let profile = try fixture.installTarget(expired: true)
        let identity = try #require(profile.codexSignIn)
        try fixture.vault.load(identity).data.write(to: fixture.authURL)
        await #expect(throws: CodexSignInSwitchError.self) { try await fixture.service.switchAndOpen(profile: profile) }
        #expect(try fixture.vault.load(identity).refreshToken == "rotated")
        // Saving or retrying must not resurrect the consumed token still in live storage.
        _ = try await fixture.service.saveCurrent(for: profile)
        #expect(try fixture.vault.load(identity).refreshToken == "rotated")
        let restarted = try NativeSwitchFixture(home: home, verifier: verifier)
        try await restarted.service.switchAndOpen(profile: profile)
        #expect(try CodexSignIn(data: Data(contentsOf: fixture.authURL)).refreshToken == "rotated")
        #expect(await verifier.refreshCount == 1)
    }

    @Test func partialCloseFailureAttemptsReopenWithoutChangingCredentials() async throws {
        let app = NativeAppStub(partialClose: true)
        let fixture = try NativeSwitchFixture(app: app)
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget()
        let before = try Data(contentsOf: fixture.authURL)
        do {
            try await fixture.service.switchAndOpen(profile: profile)
            Issue.record("Expected partial close failure")
        } catch let error as CodexSignInSwitchError {
            #expect(error.recovery == .unchanged)
        }
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(await app.events == ["close", "open"])
    }

    @Test func saveHonorsLegacyWorkspaceBindingWhenSnapshotIsMissing() async throws {
        let fixture = try NativeSwitchFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.home.appendingPathComponent(".codex/accounts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = ["account_key": "old", "chatgpt_account_id": "original-workspace", "chatgpt_user_id": "user", "email": "studio@example.com"]
        try JSONSerialization.data(withJSONObject: ["accounts": [account]]).write(to: directory.appendingPathComponent("registry.json"))
        var profile = fixture.profile
        profile.codexAccountKey = "old"
        try CodexSignInFixture.data(account: "different-workspace").write(to: fixture.authURL)
        await #expect(throws: CodexSignInError.identityMismatch) { try await fixture.service.saveCurrent(for: profile) }
    }

    @Test func failedSwitchFromSignedOutRestoresAbsentFile() async throws {
        let fixture = try NativeSwitchFixture(verifier: NativeVerifierStub(failVerification: 2))
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget()
        try FileManager.default.removeItem(at: fixture.authURL)
        await #expect(throws: CodexSignInSwitchError.self) { try await fixture.service.switchAndOpen(profile: profile) }
        #expect(!FileManager.default.fileExists(atPath: fixture.authURL.path))
        #expect(await fixture.app.events == ["close", "open"])
    }

    @Test func savesWithoutHelperAndSwitchesWhileRetainingLatestOutgoingTokens() async throws {
        let fixture = try NativeSwitchFixture()
        defer { fixture.cleanUp() }
        let selected = try CodexSignIn(data: CodexSignInFixture.data(account: "selected"))
        try selected.data.write(to: fixture.authURL)
        let saved = try await fixture.service.saveCurrent(for: fixture.profile)
        var profile = fixture.profile
        profile.codexSignIn = saved
        let outgoing = try CodexSignIn(data: CodexSignInFixture.data(account: "outgoing", refresh: "latest-outgoing"))
        try outgoing.data.write(to: fixture.authURL)
        try await fixture.service.switchAndOpen(profile: profile)
        #expect(try Data(contentsOf: fixture.authURL) == selected.data)
        #expect(try fixture.vault.load(outgoing.identity).refreshToken == "latest-outgoing")
        #expect(await fixture.app.events == ["close", "open"])
    }

    @Test func mismatchIsRejectedBeforeClosingTheApp() async throws {
        let fixture = try NativeSwitchFixture()
        defer { fixture.cleanUp() }
        try CodexSignInFixture.data().write(to: fixture.authURL)
        var profile = fixture.profile
        profile.label = "someone-else@example.com"
        await #expect(throws: CodexSignInError.identityMismatch) { try await fixture.service.saveCurrent(for: profile) }
        #expect(await fixture.app.events.isEmpty)
    }

    @Test func failedCloseDoesNotChangeCredentials() async throws {
        let app = NativeAppStub(closeError: .appCouldNotClose)
        let fixture = try NativeSwitchFixture(app: app)
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget()
        let before = try Data(contentsOf: fixture.authURL)
        await #expect(throws: CodexSignInError.appCouldNotClose) { try await fixture.service.switchAndOpen(profile: profile) }
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(await app.events == ["close"])
    }

    @Test func postWriteFailureRestoresOriginalAndReopens() async throws {
        let verifier = NativeVerifierStub(failVerification: 2)
        let fixture = try NativeSwitchFixture(verifier: verifier)
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget()
        let before = try Data(contentsOf: fixture.authURL)
        do {
            try await fixture.service.switchAndOpen(profile: profile)
            Issue.record("Expected verification failure")
        } catch let error as CodexSignInSwitchError {
            #expect(error.recovery == .restored)
        }
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(await fixture.app.events == ["close", "open"])
    }

    @Test func concurrentWriteDuringVerificationIsNeverRolledBack() async throws {
        let directory = try CodexSignInFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = try CodexSignInFixture.data(account: "concurrent")
        let authURL = directory.appendingPathComponent(".codex/auth.json")
        let verifier = NativeVerifierStub(afterVerification: { count in
            if count == 2 { try changed.write(to: authURL) }
        })
        let fixture = try NativeSwitchFixture(home: directory, verifier: verifier)
        let profile = try fixture.installTarget()
        do {
            try await fixture.service.switchAndOpen(profile: profile)
            Issue.record("Expected concurrent change")
        } catch let error as CodexSignInSwitchError {
            #expect(error.recovery == .changedExternally)
        }
        #expect(try Data(contentsOf: authURL) == changed)
        #expect(await fixture.app.events == ["close", "open"])
    }

    @Test func refreshSurvivesFollowingFailureForSelectedAndOutgoingAccounts() async throws {
        let refreshed = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "rotated"))
        let verifier = NativeVerifierStub(failVerification: 1, refreshed: refreshed)
        let fixture = try NativeSwitchFixture(verifier: verifier)
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget(expired: true)
        let before = try Data(contentsOf: fixture.authURL)
        await #expect(throws: CodexSignInSwitchError.self) { try await fixture.service.switchAndOpen(profile: profile) }
        #expect(try fixture.vault.load(refreshed.identity).refreshToken == "rotated")
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(await fixture.app.events == ["close", "open"])
    }

    @Test func sameAccountNeverRestoresConsumedRefreshToken() async throws {
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "rotated"))
        let verifier = NativeVerifierStub(failVerification: 1, refreshed: fresh)
        let fixture = try NativeSwitchFixture(verifier: verifier)
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget(expired: true)
        let identity = try #require(profile.codexSignIn)
        try fixture.vault.load(identity).data.write(to: fixture.authURL)
        do {
            try await fixture.service.switchAndOpen(profile: profile)
            Issue.record("Expected verification failure")
        } catch let error as CodexSignInSwitchError {
            #expect(error.recovery == .refreshedCurrent)
        }
        #expect(try CodexSignIn(data: Data(contentsOf: fixture.authURL)).refreshToken == "rotated")
        #expect(try fixture.vault.load(identity).refreshToken == "rotated")
    }

    @Test func reopeningFailureCannotBeReportedAsSuccess() async throws {
        let fixture = try NativeSwitchFixture(app: NativeAppStub(openError: .reopenFailed))
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget()
        do {
            try await fixture.service.switchAndOpen(profile: profile)
            Issue.record("Expected launch failure")
        } catch let error as CodexSignInSwitchError {
            #expect(error.reopenFailed)
            #expect(error.recovery == .selected)
        }
        #expect(try CodexSignIn(data: Data(contentsOf: fixture.authURL)).identity == profile.codexSignIn)
    }

    @Test func cancellationAfterRotationKeepsRotatedPairAndReopens() async throws {
        let fresh = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", refresh: "rotated"))
        let verifier = NativeVerifierStub(refreshed: fresh, afterVerification: { _ in throw CancellationError() })
        let fixture = try NativeSwitchFixture(verifier: verifier)
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget(expired: true)
        await #expect(throws: CodexSignInSwitchError.self) { try await fixture.service.switchAndOpen(profile: profile) }
        #expect(try fixture.vault.load(fresh.identity).refreshToken == "rotated")
        #expect(await fixture.app.events == ["close", "open"])
    }
}

private struct ConfiguredNativeApp: CodexDesktopAppManaging {
    let arguments: [String]

    func validateConfiguration() async throws {
        try CodexDesktopApp.validateProcess(arguments: arguments, environment: [:],
                                           standardHome: URL(fileURLWithPath: "/Users/sample/.codex"))
    }

    func close() async throws { Issue.record("Saving a sign-in must not close the desktop app") }
    func open() async throws { Issue.record("Saving a sign-in must not reopen the desktop app") }
}

struct NativeSwitchFixture {
    let home: URL
    let authURL: URL
    let vault: CodexSignInVault
    let profile = CodexSignInFixture.profile()
    let app: NativeAppStub
    let service: CodexAccountSwitchService

    init(home: URL? = nil, app: NativeAppStub = NativeAppStub(), verifier: any CodexSignInVerifying = NativeVerifierStub()) throws {
        self.home = try home ?? CodexSignInFixture.directory()
        let codex = self.home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        authURL = codex.appendingPathComponent("auth.json")
        vault = CodexSignInVault(homeDirectory: self.home)
        self.app = app
        service = CodexAccountSwitchService(homeDirectory: self.home, app: app, verifier: verifier,
                                           resolveStore: { try CodexLiveAuthStore(codexHome: codex, keychain: MemoryCodexKeychain()) })
    }

    func installTarget(expired: Bool = false) throws -> PlusProfile {
        let target = try CodexSignIn(data: CodexSignInFixture.data(account: "selected", expired: expired))
        try vault.save(target)
        try CodexSignInFixture.data(account: "outgoing").write(to: authURL)
        var result = profile
        result.codexSignIn = target.identity
        return result
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }
}

actor NativeAppStub: CodexDesktopAppManaging {
    var events: [String] = []
    let closeError: CodexSignInError?
    let openError: CodexSignInError?
    let partialClose: Bool
    init(closeError: CodexSignInError? = nil, openError: CodexSignInError? = nil, partialClose: Bool = false) {
        self.closeError = closeError; self.openError = openError
        self.partialClose = partialClose
    }
    func close() throws {
        events.append("close")
        if partialClose { throw CodexDesktopCloseError.terminationStarted }
        if let closeError { throw closeError }
    }
    func open() throws { events.append("open"); if let openError { throw openError } }
}

actor PendingNativeRefresh: CodexSignInVerifying {
    let fresh: CodexSignIn
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var returnedWhileCancelled = false
    init(fresh: CodexSignIn) { self.fresh = fresh }
    func verify(_ signIn: CodexSignIn) throws { try Task.checkCancellation() }
    func refresh(_ signIn: CodexSignIn) async throws -> CodexSignIn {
        await withCheckedContinuation {
            pending = $0
            waiter?.resume()
            waiter = nil
        }
        returnedWhileCancelled = Task.isCancelled
        return fresh
    }
    func waitForStart() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { pending?.resume(); pending = nil }
}

actor NativeVerifierStub: CodexSignInVerifying {
    private var count = 0
    private(set) var refreshCount = 0
    let failVerification: Int?
    let refreshed: CodexSignIn?
    let afterVerification: @Sendable (Int) throws -> Void
    let afterRefresh: @Sendable () throws -> Void
    init(failVerification: Int? = nil, refreshed: CodexSignIn? = nil,
         afterVerification: @escaping @Sendable (Int) throws -> Void = { _ in },
         afterRefresh: @escaping @Sendable () throws -> Void = {}) {
        self.failVerification = failVerification; self.refreshed = refreshed; self.afterVerification = afterVerification
        self.afterRefresh = afterRefresh
    }
    func verify(_ signIn: CodexSignIn) throws {
        count += 1
        try afterVerification(count)
        if count == failVerification { throw CodexSignInError.unavailable }
    }
    func refresh(_ signIn: CodexSignIn) throws -> CodexSignIn {
        refreshCount += 1
        try afterRefresh()
        return refreshed ?? signIn
    }
}

struct DesktopControllerStub: CodexAccountSwitchServing {
    let identity: CodexSignInIdentity?
    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity {
        guard let identity else { throw CodexSignInError.identityMismatch }
        return identity
    }
    func switchAndOpen(profile: PlusProfile) async throws {}
}

actor PendingDesktopSaveService: CodexAccountSwitchServing {
    private var pending: CheckedContinuation<CodexSignInIdentity, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity {
        await withCheckedContinuation { continuation in
            pending = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func waitForStart() async {
        if pending != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() {
        pending?.resume(returning: .init(accountID: "workspace", userID: "user", email: "studio@example.com"))
        pending = nil
    }
    func switchAndOpen(profile: PlusProfile) async throws {}
}
