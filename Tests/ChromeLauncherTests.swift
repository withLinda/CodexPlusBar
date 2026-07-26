import Foundation
import Testing
@testable import CodexPlusBar

@MainActor
struct ChromeLauncherTests {
    @Test
    func devToolsActivePortReaderBuildsLocalBrowserEndpoint() throws {
        let directory = makeTemporaryDirectory()
        try """
        51046
        /devtools/browser/browser-id
        """.write(
            to: directory.appendingPathComponent("DevToolsActivePort", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let endpoint = try ChromeLauncher.readDevToolsEndpoint(in: directory)

        #expect(endpoint.port == 51046)
        #expect(endpoint.browserURL.absoluteString == "http://127.0.0.1:51046/json/version")
    }

    @Test
    func launchUsesDedicatedProfileAndReadsDevToolsPort() async throws {
        let profile = sampleProfile()
        let rootDirectory = makeTemporaryDirectory()
        let recorder = LaunchRecorder()
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: URL(fileURLWithPath: "/tmp/fake-chrome")),
            profileStore: ChromeProfileStore(rootDirectory: rootDirectory),
            launchProcess: { _, arguments in
                recorder.arguments = arguments

                let prefix = "--user-data-dir="
                let profileDirectoryArgument = try #require(
                    arguments.first(where: { $0.hasPrefix(prefix) })
                )
                let profileDirectory = URL(
                    fileURLWithPath: String(profileDirectoryArgument.dropFirst(prefix.count)),
                    isDirectory: true
                )
                try """
                51046
                /devtools/browser/browser-id
                """.write(
                    to: profileDirectory.appendingPathComponent("DevToolsActivePort", isDirectory: false),
                    atomically: true,
                    encoding: .utf8
                )

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            },
            sleep: { _ in }
        )

        let session = try await launcher.launch(profile: profile)

        #expect(session.profileID == profile.id)
        #expect(session.profileDirectory == rootDirectory.appendingPathComponent(profile.webDataStoreID.uuidString, isDirectory: true))
        #expect(session.endpoint?.browserURL.absoluteString == "http://127.0.0.1:51046/json/version")
        #expect(recorder.arguments.contains("--remote-debugging-port=0"))
        #expect(recorder.arguments.contains("--remote-debugging-address=127.0.0.1"))
        #expect(recorder.arguments.contains("--no-first-run"))
        #expect(recorder.arguments.contains(ChatGPTWebURLs.loginPage.absoluteString))
        #expect(recorder.arguments.contains("--user-data-dir=\(session.profileDirectory.path)"))
    }

    @Test
    func visibleSignInLaunchDoesNotExposeRemoteDebugging() async throws {
        let profile = sampleProfile()
        let recorder = LaunchRecorder()
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: URL(fileURLWithPath: "/tmp/fake-chrome")),
            profileStore: ChromeProfileStore(rootDirectory: makeTemporaryDirectory()),
            launchProcess: { _, arguments in
                recorder.arguments = arguments
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            },
            sleep: { _ in }
        )

        let session = try await launcher.launch(
            profile: profile,
            mode: .visible,
            initialURL: ChatGPTWebURLs.loginPage,
            requiresDevTools: false
        )

        #expect(session.endpoint == nil)
        #expect(recorder.arguments.contains("--remote-debugging-port=0") == false)
        #expect(recorder.arguments.contains("--remote-debugging-address=127.0.0.1") == false)
        #expect(recorder.arguments.contains("--headless=new") == false)
        #expect(recorder.arguments.contains("--new-window"))
        #expect(recorder.arguments.contains(ChatGPTWebURLs.loginPage.absoluteString))
    }

    @Test
    func openSignInStartsGoogleAccountHintAndChatGPTLoginTabs() async throws {
        let profile = sampleProfile()
        let recorder = LaunchRecorder()
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: URL(fileURLWithPath: "/tmp/fake-chrome")),
            profileStore: ChromeProfileStore(rootDirectory: makeTemporaryDirectory()),
            launchProcess: { _, arguments in
                recorder.arguments = arguments
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            },
            sleep: { _ in }
        )
        let manager = DefaultChromeSessionManager(launcher: launcher)

        try await manager.openSignIn(for: profile)

        let launchedURLs = recorder.arguments.compactMap(URL.init(string:))
        let googleURL = try #require(
            launchedURLs.first { $0.host == "accounts.google.com" }
        )
        let components = try #require(URLComponents(url: googleURL, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        let queryValues = Dictionary(
            uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
                guard let value = item.value else {
                    return nil
                }

                return (item.name, value)
            }
        )

        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(queryValues["login_hint"] == "linda.fitriani@gmail.com")
        #expect(queryValues["service"] == "chromiumsync")
        #expect(queryValues["continue"] == nil)
        #expect(launchedURLs.contains(ChatGPTWebURLs.loginPage))
        #expect(recorder.arguments.contains("--remote-debugging-port=0") == false)
    }

    @Test
    func claudeSignInOpensClaudeInsteadOfChatGPT() async throws {
        let profile = sampleProfile(provider: .claude)
        let recorder = LaunchRecorder()
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: URL(fileURLWithPath: "/tmp/fake-chrome")),
            profileStore: ChromeProfileStore(rootDirectory: makeTemporaryDirectory()),
            launchProcess: { _, arguments in
                recorder.arguments = arguments
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            },
            sleep: { _ in }
        )
        let manager = DefaultChromeSessionManager(launcher: launcher)

        try await manager.openSignIn(for: profile)

        let launchedURLs = recorder.arguments.compactMap(URL.init(string:))
        #expect(launchedURLs.contains(ClaudeWebURLs.loginPage))
        #expect(launchedURLs.contains(ChatGPTWebURLs.loginPage) == false)
    }

    @Test
    func signInFinishDetectorWaitsUntilUserReturnsFromBrowser() {
        var detector = ChromeSignInFinishDetector(isHostApplicationActive: true)

        let stayedInApp = detector.shouldFinish(
            isHostApplicationActive: true,
            isBrowserRunning: true
        )
        let enteredBrowser = detector.shouldFinish(
            isHostApplicationActive: false,
            isBrowserRunning: true
        )
        let returnedToApp = detector.shouldFinish(
            isHostApplicationActive: true,
            isBrowserRunning: true
        )

        #expect(stayedInApp == false)
        #expect(enteredBrowser == false)
        #expect(returnedToApp)
    }

    @Test
    func signInFinishDetectorAlsoFinishesWhenBrowserQuits() {
        var detector = ChromeSignInFinishDetector(isHostApplicationActive: true)

        let browserQuit = detector.shouldFinish(
            isHostApplicationActive: true,
            isBrowserRunning: false
        )

        #expect(browserQuit)
    }

    @Test
    func passkeySetupLaunchUsesVisibleDedicatedProfileWithoutDevTools() async throws {
        let profile = sampleProfile()
        let recorder = LaunchRecorder()
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: URL(fileURLWithPath: "/tmp/fake-chrome")),
            profileStore: ChromeProfileStore(rootDirectory: makeTemporaryDirectory()),
            launchProcess: { _, arguments in
                recorder.arguments = arguments
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            },
            sleep: { _ in }
        )

        let session = try await launcher.launchPasskeySetup(profile: profile)

        #expect(session.endpoint == nil)
        #expect(recorder.arguments.contains("--remote-debugging-port=0") == false)
        #expect(recorder.arguments.contains("--remote-debugging-address=127.0.0.1") == false)
        #expect(recorder.arguments.contains("--headless=new") == false)
        #expect(recorder.arguments.contains("--new-window"))
        #expect(recorder.arguments.contains(ChatGPTWebURLs.passkeySetupPage.absoluteString))
        #expect(recorder.arguments.contains("--user-data-dir=\(session.profileDirectory.path)"))
    }

    @Test
    func headlessInspectorLaunchKeepsRemoteDebuggingLocalOnly() async throws {
        let profile = sampleProfile()
        let recorder = LaunchRecorder()
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: URL(fileURLWithPath: "/tmp/fake-chrome")),
            profileStore: ChromeProfileStore(rootDirectory: makeTemporaryDirectory()),
            launchProcess: { _, arguments in
                recorder.arguments = arguments

                let prefix = "--user-data-dir="
                let profileDirectoryArgument = try #require(
                    arguments.first(where: { $0.hasPrefix(prefix) })
                )
                let profileDirectory = URL(
                    fileURLWithPath: String(profileDirectoryArgument.dropFirst(prefix.count)),
                    isDirectory: true
                )
                try """
                51046
                /devtools/browser/browser-id
                """.write(
                    to: profileDirectory.appendingPathComponent("DevToolsActivePort", isDirectory: false),
                    atomically: true,
                    encoding: .utf8
                )

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            },
            sleep: { _ in }
        )

        let session = try await launcher.launch(
            profile: profile,
            mode: .headless,
            initialURL: ChatGPTWebURLs.cookieScope,
            requiresDevTools: true
        )

        #expect(session.endpoint?.browserURL.absoluteString == "http://127.0.0.1:51046/json/version")
        #expect(recorder.arguments.contains("--remote-debugging-port=0"))
        #expect(recorder.arguments.contains("--remote-debugging-address=127.0.0.1"))
        #expect(recorder.arguments.contains("--headless=new"))
        #expect(recorder.arguments.contains("about:blank"))
    }

    @Test
    func launchFailsClearlyWhenChromeIsMissing() async throws {
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: nil),
            profileStore: ChromeProfileStore(rootDirectory: makeTemporaryDirectory())
        )

        var thrownError: ChatGPTAPIError?
        do {
            _ = try await launcher.launch(profile: sampleProfile())
        } catch {
            thrownError = ChatGPTAPIError.map(error)
        }

        #expect(thrownError == .unsupported("Google Chrome is not installed on this Mac."))
    }

    @Test
    func launchTimeoutMapsToSimpleNetworkMessage() async throws {
        let launcher = ChromeLauncher(
            appLocator: StubChromeLocator(executableURL: URL(fileURLWithPath: "/tmp/fake-chrome")),
            profileStore: ChromeProfileStore(rootDirectory: makeTemporaryDirectory()),
            launchProcess: { _, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            },
            sleep: { _ in }
        )

        var thrownError: ChatGPTAPIError?
        do {
            _ = try await launcher.launch(profile: sampleProfile())
        } catch {
            thrownError = ChatGPTAPIError.map(error)
        }

        #expect(thrownError == .network("Chrome did not open its sign-in connection in time."))
    }
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class LaunchRecorder: @unchecked Sendable {
    var arguments: [String] = []
}

private struct StubChromeLocator: ChromeAppLocating {
    let executableURL: URL?

    func chromeExecutableURL() -> URL? {
        executableURL
    }
}

private func sampleProfile(provider: ProfileProvider = .codex) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        provider: provider,
        label: "chrome@example.com",
        emailLink: nil,
        detectedNote: nil,
        webDataStoreID: UUID(),
        sortOrder: 0,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}
