import AppKit
import Darwin
import Foundation

struct ChromeCookieImportResult: Equatable, Sendable {
    let importedCookieCount: Int
}

struct ChromeSignInFinishDetector: Sendable {
    private var didLeaveHostApplication: Bool

    init(isHostApplicationActive: Bool) {
        didLeaveHostApplication = isHostApplicationActive == false
    }

    mutating func shouldFinish(
        isHostApplicationActive: Bool,
        isBrowserRunning: Bool
    ) -> Bool {
        guard isBrowserRunning else {
            return true
        }

        if isHostApplicationActive == false {
            didLeaveHostApplication = true
            return false
        }

        return didLeaveHostApplication
    }
}

/// Chrome permits only one browser process for a user-data directory.  The
/// profile refresh code can ask for several restores at the same time, so the
/// shared-root manager needs a real async mutex rather than relying on
/// `@MainActor` alone (actor-isolated methods can still overlap at `await`).
private actor ChromeOperationLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
protocol ChromeSessionManaging: AnyObject {
    func openAccountPage(for profile: PlusProfile) async throws
    func openSignIn(for profile: PlusProfile) async throws
    func openPasskeySetup(for profile: PlusProfile) async throws
    func syncCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult
    func restoreCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult
    func waitForSignInToFinish(for profile: PlusProfile) async -> Bool
    func clearCookies(for profile: PlusProfile) async throws
    func removeProfileData(for profile: PlusProfile) async throws
    func closeSignIn(for profile: PlusProfile) async
}

@MainActor
final class DefaultChromeSessionManager: ChromeSessionManaging {
    private enum ActiveSessionPurpose {
        case accountPage
        case signIn
        case passkeySetup
    }

    private struct ActiveSession {
        let session: ChromeLaunchedSession
        let purpose: ActiveSessionPurpose
        let provider: ProfileProvider
    }

    private let launcher: ChromeLauncher
    private let profileStore: ChromeProfileStore
    private let makeClient: @MainActor (ChromeDevToolsEndpoint) async throws -> ChromeDevToolsClient
    private let operationLock = ChromeOperationLock()
    private var activeSession: ActiveSession?

    init(
        launcher: ChromeLauncher = ChromeLauncher(),
        profileStore: ChromeProfileStore? = nil,
        makeClient: @escaping @MainActor (ChromeDevToolsEndpoint) async throws -> ChromeDevToolsClient = {
            try await ChromeDevToolsClient.connect(versionURL: $0.browserURL)
        }
    ) {
        self.launcher = launcher
        self.profileStore = profileStore ?? launcher.profileStore
        self.makeClient = makeClient
    }

    func openAccountPage(for profile: PlusProfile) async throws {
        try await withExclusiveOperation {
            try await self.openAccountPageUnlocked(for: profile)
        }
    }

    private func openAccountPageUnlocked(for profile: PlusProfile) async throws {
        try await closeActiveSession()
        let session = try await launcher.launch(
            profile: profile,
            mode: .visible,
            initialURL: accountPage(for: profile.provider),
            requiresDevTools: false,
            storagePolicy: .minimal
        )
        activeSession = ActiveSession(
            session: session,
            purpose: .accountPage,
            provider: profile.provider
        )
    }

    func openSignIn(for profile: PlusProfile) async throws {
        try await withExclusiveOperation {
            try await self.openSignInUnlocked(for: profile)
        }
    }

    private func openSignInUnlocked(for profile: PlusProfile) async throws {
        if let activeSession,
           activeSession.session.profileID == profile.id,
           activeSession.purpose == .signIn,
           activeSession.provider == profile.provider,
           isProcessRunning(activeSession.session.processIdentifier) {
            NSRunningApplication(
                processIdentifier: activeSession.session.processIdentifier
            )?.activate(options: [.activateAllWindows])
            return
        }

        try await closeActiveSession()

        let session = try await launcher.launch(
            profile: profile,
            mode: .visible,
            initialURLs: [
                ChromeBrowserSignInURLs.googleSyncSignInPage,
                signInURL(for: profile.provider),
            ],
            requiresDevTools: false,
            storagePolicy: .signIn
        )
        activeSession = ActiveSession(
            session: session,
            purpose: .signIn,
            provider: profile.provider
        )
    }

    func openPasskeySetup(for profile: PlusProfile) async throws {
        try await withExclusiveOperation {
            try await self.openPasskeySetupUnlocked(for: profile)
        }
    }

    private func openPasskeySetupUnlocked(for profile: PlusProfile) async throws {
        guard profile.provider == .codex else {
            throw ChatGPTAPIError.unsupported(
                "Touch ID help is only available for Codex profiles."
            )
        }

        if let activeSession,
           activeSession.session.profileID == profile.id,
           activeSession.purpose == .passkeySetup,
           activeSession.provider == profile.provider,
           isProcessRunning(activeSession.session.processIdentifier) {
            NSRunningApplication(
                processIdentifier: activeSession.session.processIdentifier
            )?.activate(options: [.activateAllWindows])
            return
        }

        try await closeActiveSession()

        let session = try await launcher.launchPasskeySetup(profile: profile)
        activeSession = ActiveSession(
            session: session,
            purpose: .passkeySetup,
            provider: profile.provider
        )
    }

    func syncCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult {
        do {
            return try await withExclusiveOperation {
                guard let session = self.activeSession,
                      session.session.profileID == profile.id,
                      session.purpose == .signIn,
                      session.provider == profile.provider else {
                    throw ChatGPTAPIError.unsupported("Open Chrome sign-in first, then sync.")
                }

                try await self.closeActiveSession()

                return try await self.importCookies(
                    for: profile,
                    into: sessionStore
                )
            }
        } catch {
            if ChatGPTAPIError.map(error) == .unauthorized {
                _ = try? await openSignIn(for: profile)
            }
            throw error
        }
    }

    func restoreCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult {
        try await withExclusiveOperation {
            guard self.profileStore.hasProfileDirectory(for: profile) else {
                throw ChatGPTAPIError.unauthorized
            }

            try await self.closeActiveSession()

            return try await self.importCookies(
                for: profile,
                into: sessionStore
            )
        }
    }

    func waitForSignInToFinish(for profile: PlusProfile) async -> Bool {
        guard let activeSession,
              activeSession.session.profileID == profile.id,
              activeSession.purpose == .signIn,
              activeSession.provider == profile.provider
        else {
            return false
        }

        let processIdentifier = activeSession.session.processIdentifier
        var finishDetector = ChromeSignInFinishDetector(
            isHostApplicationActive: NSApplication.shared.isActive
        )

        while Task.isCancelled == false {
            guard let currentSession = self.activeSession,
                  currentSession.session.processIdentifier == processIdentifier
            else {
                return false
            }

            let browserApplication = NSRunningApplication(
                processIdentifier: processIdentifier
            )
            if finishDetector.shouldFinish(
                isHostApplicationActive: NSApplication.shared.isActive,
                isBrowserRunning: browserApplication?.isTerminated == false
            ) {
                return true
            }

            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return false
            }
        }

        return false
    }

    private func importCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult {
        let inspectorSession = try await launcher.launch(
            profile: profile,
            mode: .headless,
            initialURL: cookieScope(for: profile.provider),
            requiresDevTools: true,
            storagePolicy: .minimal
        )
        var client: ChromeDevToolsClient?

        do {
            client = try await makeClient(for: inspectorSession)
            guard let client else {
                throw ChatGPTAPIError.invalidResponse
            }

            let cookies = try await client.getCookies()
            let importedCookieCount = try await ChromeCookieImporter.storeCookies(
                from: cookies,
                for: profile.provider,
                in: sessionStore
            )
            await closeInspectorSession(client: client, session: inspectorSession)
            return ChromeCookieImportResult(importedCookieCount: importedCookieCount)
        } catch {
            await closeInspectorSession(client: client, session: inspectorSession)
            throw error
        }
    }

    func clearCookies(for profile: PlusProfile) async throws {
        try await withExclusiveOperation {
            try await self.closeActiveSession()

            guard self.profileStore.hasProfileDirectory(for: profile) else {
                return
            }

            let session = try await self.launcher.launch(
                profile: profile,
                mode: .headless,
                initialURL: self.cookieScope(for: profile.provider),
                requiresDevTools: true,
                storagePolicy: .minimal
            )
            var client: ChromeDevToolsClient?

            do {
                client = try await self.makeClient(for: session)
                guard let client else {
                    throw ChatGPTAPIError.invalidResponse
                }

                try await client.clearCookies()
                await self.closeInspectorSession(client: client, session: session)
            } catch {
                await self.closeInspectorSession(client: client, session: session)
                throw error
            }
        }
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        try await withExclusiveOperation {
            try await self.closeActiveSession()
            try self.profileStore.removeProfileDirectory(for: profile)
        }
    }

    func closeSignIn(for profile: PlusProfile) async {
        _ = try? await withExclusiveOperation {
            guard let activeSession = self.activeSession,
                  activeSession.session.profileID == profile.id else {
                return
            }

            try await self.closeActiveSession()
        }
    }

    private func withExclusiveOperation<Result>(
        _ operation: @escaping @MainActor () async throws -> Result
    ) async throws -> Result {
        await operationLock.acquire()
        do {
            let result = try await operation()
            await operationLock.release()
            return result
        } catch {
            await operationLock.release()
            throw error
        }
    }

    private func makeClient(for session: ChromeLaunchedSession) async throws -> ChromeDevToolsClient {
        guard let endpoint = session.endpoint else {
            throw ChatGPTAPIError.invalidResponse
        }

        return try await makeClient(endpoint)
    }

    private func signInURL(for provider: ProfileProvider) -> URL {
        switch provider {
        case .codex:
            return ChatGPTWebURLs.loginPage
        case .claude:
            return ClaudeWebURLs.loginPage
        }
    }

    private func accountPage(for provider: ProfileProvider) -> URL {
        switch provider {
        case .codex:
            return ChatGPTWebURLs.usagePage
        case .claude:
            return ClaudeWebURLs.usagePage
        }
    }

    private func cookieScope(for provider: ProfileProvider) -> URL {
        switch provider {
        case .codex:
            return ChatGPTWebURLs.cookieScope
        case .claude:
            return ClaudeWebURLs.cookieScope
        }
    }

    private func closeInspectorSession(
        client: ChromeDevToolsClient?,
        session: ChromeLaunchedSession
    ) async {
        if let client {
            do {
                try await client.closeBrowser()
            } catch {
                // Fall through to a normal process termination. The primary cookie action already finished.
            }
        }

        if await terminateProcessIfNeeded(session.processIdentifier) {
            cleanupAfterChromeSession(session)
        }
    }

    private func closeActiveSession() async throws {
        guard let activeSession else {
            return
        }

        guard await terminateProcessIfNeeded(activeSession.session.processIdentifier) else {
            throw ChatGPTAPIError.network(
                "Chrome is still closing. Please wait a moment and try again."
            )
        }

        self.activeSession = nil
        cleanupAfterChromeSession(activeSession.session)
    }

    private func cleanupAfterChromeSession(_ session: ChromeLaunchedSession) {
        _ = try? profileStore.pruneDisposableData(in: session.profileDirectory)
        _ = try? profileStore.pruneSharedDisposableData()
    }

    private func terminateProcessIfNeeded(_ processIdentifier: Int32) async -> Bool {
        guard processIdentifier > 0 else {
            return true
        }

        if let application = NSRunningApplication(processIdentifier: processIdentifier) {
            guard application.isTerminated == false else {
                return true
            }

            application.terminate()

            if await waitForTermination(of: application, attempts: 30) {
                return true
            }

            application.forceTerminate()
            return await waitForTermination(of: application, attempts: 20)
        }

        guard isProcessRunning(processIdentifier) else {
            return true
        }

        if Darwin.kill(processIdentifier, SIGTERM) != 0, errno == ESRCH {
            return true
        }

        for _ in 0..<30 {
            guard isProcessRunning(processIdentifier) else {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return isProcessRunning(processIdentifier) == false
    }

    private func waitForTermination(
        of application: NSRunningApplication,
        attempts: Int
    ) async -> Bool {
        for _ in 0..<attempts {
            if application.isTerminated {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return application.isTerminated
    }

    private func isProcessRunning(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else {
            return false
        }

        if let application = NSRunningApplication(processIdentifier: processIdentifier) {
            return application.isTerminated == false
        }

        if Darwin.kill(processIdentifier, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}
