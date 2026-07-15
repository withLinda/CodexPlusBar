import AppKit
import Darwin
import Foundation

struct ChromeCookieImportResult: Equatable, Sendable {
    let importedCookieCount: Int
}

@MainActor
protocol ChromeSessionManaging: AnyObject {
    func openSignIn(for profile: PlusProfile) async throws
    func openPasskeySetup(for profile: PlusProfile) async throws
    func syncCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult
    func clearCookies(for profile: PlusProfile) async throws
    func removeProfileData(for profile: PlusProfile) async throws
    func closeSignIn(for profile: PlusProfile) async
}

@MainActor
final class DefaultChromeSessionManager: ChromeSessionManaging {
    private enum ActiveSessionPurpose {
        case signIn
        case passkeySetup
    }

    private struct ActiveSession {
        let session: ChromeLaunchedSession
        let purpose: ActiveSessionPurpose
    }

    private let launcher: ChromeLauncher
    private let profileStore: ChromeProfileStore
    private let fileManager: FileManager
    private let makeClient: @MainActor (ChromeDevToolsEndpoint) async throws -> ChromeDevToolsClient
    private var activeSessionsByProfileID: [UUID: ActiveSession] = [:]

    init(
        launcher: ChromeLauncher = ChromeLauncher(),
        profileStore: ChromeProfileStore = ChromeProfileStore(),
        fileManager: FileManager = .default,
        makeClient: @escaping @MainActor (ChromeDevToolsEndpoint) async throws -> ChromeDevToolsClient = {
            try await ChromeDevToolsClient.connect(versionURL: $0.browserURL)
        }
    ) {
        self.launcher = launcher
        self.profileStore = profileStore
        self.fileManager = fileManager
        self.makeClient = makeClient
    }

    func openSignIn(for profile: PlusProfile) async throws {
        if let activeSession = activeSessionsByProfileID[profile.id],
           activeSession.purpose == .signIn {
            NSRunningApplication(
                processIdentifier: activeSession.session.processIdentifier
            )?.activate(options: [.activateAllWindows])
            return
        }

        if let activeSession = activeSessionsByProfileID.removeValue(forKey: profile.id) {
            await terminateProcessIfNeeded(activeSession.session.processIdentifier)
        }

        let session = try await launcher.launch(
            profile: profile,
            mode: .visible,
            initialURLs: [
                ChromeBrowserSignInURLs.googleSyncSignInPage,
                ChatGPTWebURLs.loginPage,
            ],
            requiresDevTools: false
        )
        activeSessionsByProfileID[profile.id] = ActiveSession(session: session, purpose: .signIn)
    }

    func openPasskeySetup(for profile: PlusProfile) async throws {
        if let activeSession = activeSessionsByProfileID[profile.id],
           activeSession.purpose == .passkeySetup {
            NSRunningApplication(
                processIdentifier: activeSession.session.processIdentifier
            )?.activate(options: [.activateAllWindows])
            return
        }

        if let activeSession = activeSessionsByProfileID.removeValue(forKey: profile.id) {
            await terminateProcessIfNeeded(activeSession.session.processIdentifier)
        }

        let session = try await launcher.launchPasskeySetup(profile: profile)
        activeSessionsByProfileID[profile.id] = ActiveSession(session: session, purpose: .passkeySetup)
    }

    func syncCookies(
        for profile: PlusProfile,
        into sessionStore: WebSessionStore
    ) async throws -> ChromeCookieImportResult {
        guard let session = activeSessionsByProfileID[profile.id] else {
            throw ChatGPTAPIError.unsupported("Open Chrome sign-in first, then sync.")
        }

        activeSessionsByProfileID.removeValue(forKey: profile.id)
        await terminateProcessIfNeeded(session.session.processIdentifier)

        let inspectorSession = try await launcher.launch(
            profile: profile,
            mode: .headless,
            initialURL: ChatGPTWebURLs.cookieScope,
            requiresDevTools: true
        )
        var client: ChromeDevToolsClient?

        do {
            client = try await makeClient(for: inspectorSession)
            guard let client else {
                throw ChatGPTAPIError.invalidResponse
            }

            let cookies = try await client.getCookies()
            let importedCookieCount = try await ChromeCookieImporter.storeChatGPTCookies(
                from: cookies,
                in: sessionStore
            )
            await closeInspectorSession(client: client, processIdentifier: inspectorSession.processIdentifier)
            return ChromeCookieImportResult(importedCookieCount: importedCookieCount)
        } catch {
            await closeInspectorSession(client: client, processIdentifier: inspectorSession.processIdentifier)

            if ChatGPTAPIError.map(error) == .unauthorized {
                try? await openSignIn(for: profile)
            }

            throw error
        }
    }

    func clearCookies(for profile: PlusProfile) async throws {
        if let activeSession = activeSessionsByProfileID.removeValue(forKey: profile.id) {
            await terminateProcessIfNeeded(activeSession.session.processIdentifier)
        }

        let profileDirectory = profileStore.profileDirectory(for: profile)
        guard fileManager.fileExists(atPath: profileDirectory.path) else {
            return
        }

        let session = try await launcher.launch(
            profile: profile,
            mode: .headless,
            initialURL: ChatGPTWebURLs.cookieScope,
            requiresDevTools: true
        )
        var client: ChromeDevToolsClient?

        do {
            client = try await makeClient(for: session)
            guard let client else {
                throw ChatGPTAPIError.invalidResponse
            }

            try await client.clearCookies()
            await closeInspectorSession(client: client, processIdentifier: session.processIdentifier)
        } catch {
            await closeInspectorSession(client: client, processIdentifier: session.processIdentifier)
            throw error
        }
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        await closeSignIn(for: profile)
        try profileStore.removeProfileDirectory(for: profile)
    }

    func closeSignIn(for profile: PlusProfile) async {
        guard let session = activeSessionsByProfileID.removeValue(forKey: profile.id) else {
            return
        }

        await terminateProcessIfNeeded(session.session.processIdentifier)
    }

    private func makeClient(for session: ChromeLaunchedSession) async throws -> ChromeDevToolsClient {
        guard let endpoint = session.endpoint else {
            throw ChatGPTAPIError.invalidResponse
        }

        return try await makeClient(endpoint)
    }

    private func closeInspectorSession(
        client: ChromeDevToolsClient?,
        processIdentifier: Int32
    ) async {
        if let client {
            do {
                try await client.closeBrowser()
                return
            } catch {
                // Fall through to a normal process termination. The primary cookie action already finished.
            }
        }

        await terminateProcessIfNeeded(processIdentifier)
    }

    private func terminateProcessIfNeeded(_ processIdentifier: Int32) async {
        guard processIdentifier > 0 else {
            return
        }

        if let application = NSRunningApplication(processIdentifier: processIdentifier) {
            application.terminate()

            for _ in 0..<30 {
                if application.isTerminated {
                    return
                }

                try? await Task.sleep(for: .milliseconds(100))
            }

            application.forceTerminate()
            return
        }

        Darwin.kill(processIdentifier, SIGTERM)
    }
}
