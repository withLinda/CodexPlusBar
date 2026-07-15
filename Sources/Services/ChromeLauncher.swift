import AppKit
import Foundation

struct ChromeDevToolsEndpoint: Equatable, Sendable {
    let port: Int
    let browserURL: URL
}

struct ChromeLaunchedSession: Sendable {
    let profileID: UUID
    let profileDirectory: URL
    let processIdentifier: Int32
    let endpoint: ChromeDevToolsEndpoint?
}

protocol ChromeAppLocating: Sendable {
    func chromeExecutableURL() -> URL?
}

struct ChromeAppLocator: ChromeAppLocating {
    func chromeExecutableURL() -> URL? {
        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome"
        ),
            let executableURL = executableURL(forApplicationAt: applicationURL) {
            return executableURL
        }

        let candidateApplications = [
            URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("Google Chrome.app", isDirectory: true),
        ]

        return candidateApplications.lazy.compactMap(executableURL).first
    }

    private func executableURL(forApplicationAt applicationURL: URL) -> URL? {
        let executableURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Google Chrome", isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        return executableURL
    }
}

@MainActor
final class ChromeLauncher {
    enum LaunchMode: Sendable {
        case visible
        case headless
    }

    private let appLocator: ChromeAppLocating
    private let profileStore: ChromeProfileStore
    private let launchProcess: @MainActor @Sendable (URL, [String]) throws -> Process
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(
        appLocator: ChromeAppLocating = ChromeAppLocator(),
        profileStore: ChromeProfileStore = ChromeProfileStore(),
        launchProcess: @escaping @MainActor @Sendable (URL, [String]) throws -> Process = ChromeLauncher.defaultLaunchProcess,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(for: .nanoseconds(Int64(clamping: $0)))
        }
    ) {
        self.appLocator = appLocator
        self.profileStore = profileStore
        self.launchProcess = launchProcess
        self.sleep = sleep
    }

    func launch(
        profile: PlusProfile,
        mode: LaunchMode = .visible,
        initialURL: URL = ChatGPTWebURLs.loginPage,
        requiresDevTools: Bool = true
    ) async throws -> ChromeLaunchedSession {
        try await launch(
            profile: profile,
            mode: mode,
            initialURLs: [initialURL],
            requiresDevTools: requiresDevTools
        )
    }

    func launch(
        profile: PlusProfile,
        mode: LaunchMode,
        initialURLs: [URL],
        requiresDevTools: Bool
    ) async throws -> ChromeLaunchedSession {
        guard let chromeExecutableURL = appLocator.chromeExecutableURL() else {
            throw ChatGPTAPIError.unsupported("Google Chrome is not installed on this Mac.")
        }

        let profileDirectory = try profileStore.ensureProfileDirectory(for: profile)
        removeStaleDevToolsPortFile(in: profileDirectory)

        let process = try launchProcess(
            chromeExecutableURL,
            arguments(
                profileDirectory: profileDirectory,
                mode: mode,
                initialURLs: initialURLs,
                requiresDevTools: requiresDevTools
            )
        )
        let endpoint = requiresDevTools
            ? try await waitForDevToolsEndpoint(in: profileDirectory)
            : nil

        return ChromeLaunchedSession(
            profileID: profile.id,
            profileDirectory: profileDirectory,
            processIdentifier: process.processIdentifier,
            endpoint: endpoint
        )
    }

    func launchPasskeySetup(profile: PlusProfile) async throws -> ChromeLaunchedSession {
        try await launch(
            profile: profile,
            mode: .visible,
            initialURL: ChatGPTWebURLs.passkeySetupPage,
            requiresDevTools: false
        )
    }

    nonisolated static func readDevToolsEndpoint(
        in profileDirectory: URL
    ) throws -> ChromeDevToolsEndpoint {
        let portFileURL = profileDirectory.appendingPathComponent(
            "DevToolsActivePort",
            isDirectory: false
        )
        let contents = try String(contentsOf: portFileURL, encoding: .utf8)
        let lines = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        guard let firstLine = lines.first,
              let port = Int(firstLine),
              let browserURL = URL(string: "http://127.0.0.1:\(port)/json/version")
        else {
            throw ChatGPTAPIError.invalidResponse
        }

        return ChromeDevToolsEndpoint(port: port, browserURL: browserURL)
    }

    private func arguments(
        profileDirectory: URL,
        mode: LaunchMode,
        initialURLs: [URL],
        requiresDevTools: Bool
    ) -> [String] {
        var arguments = [
            "--user-data-dir=\(profileDirectory.path)",
            "--no-first-run",
        ]

        if requiresDevTools {
            arguments.append("--remote-debugging-port=0")
            arguments.append("--remote-debugging-address=127.0.0.1")
        }

        switch mode {
        case .visible:
            arguments.append("--new-window")
            arguments.append(contentsOf: initialURLs.map(\.absoluteString))
        case .headless:
            arguments.append("--headless=new")
            arguments.append("--disable-gpu")
            arguments.append("about:blank")
        }

        return arguments
    }

    private func waitForDevToolsEndpoint(
        in profileDirectory: URL
    ) async throws -> ChromeDevToolsEndpoint {
        let attempts = 100
        for _ in 0..<attempts {
            do {
                return try Self.readDevToolsEndpoint(in: profileDirectory)
            } catch {
                try await sleep(100_000_000)
            }
        }

        throw ChatGPTAPIError.network("Chrome did not open its sign-in connection in time.")
    }

    private func removeStaleDevToolsPortFile(in profileDirectory: URL) {
        let portFileURL = profileDirectory.appendingPathComponent(
            "DevToolsActivePort",
            isDirectory: false
        )

        try? FileManager.default.removeItem(at: portFileURL)
    }

    private static func defaultLaunchProcess(
        executableURL: URL,
        arguments: [String]
    ) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        return process
    }
}
