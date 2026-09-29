import AppKit
import Darwin

protocol CodexDesktopAppManaging: Sendable {
    func validateConfiguration() async throws
    func close() async throws
    func open() async throws
}

extension CodexDesktopAppManaging {
    func validateConfiguration() async throws {}
}

enum CodexDesktopCloseError: Error { case terminationStarted }

struct CodexDesktopApp: CodexDesktopAppManaging {
    static let bundleIdentifier = "com.openai.codex"

    @MainActor func validateConfiguration() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { return }
        guard let pids = Self.bundledProcesses(url) else { throw CodexSignInError.unsupportedConfiguration }
        for pid in pids {
            do {
                let (arguments, environment) = try Self.processConfiguration(pid)
                try Self.validateProcess(arguments: arguments, environment: environment,
                                         standardHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
            } catch {
                // A process that exited during inspection no longer selects a live backend.
                if kill(pid, 0) == -1, errno == ESRCH { continue }
                throw error
            }
        }
    }

    static func validateProcess(arguments: [String], environment: [String: String], standardHome: URL) throws {
        if let home = environment["CODEX_HOME"], !home.isEmpty,
           URL(fileURLWithPath: home).resolvingSymlinksInPath() != standardHome.resolvingSymlinksInPath() {
            throw CodexSignInError.unsupportedConfiguration
        }
        let overrides = ["CODEX_AUTH_JSON", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "CODEX_REFRESH_TOKEN_URL_OVERRIDE", "CODEX_APP_SERVER_LOGIN_CLIENT_ID"]
        let selectors = ["cli_auth_credentials_store", "forced_login_method", "forced_chatgpt_workspace_id", "chatgpt_base_url", "secret_auth_storage"]
        guard !overrides.contains(where: { environment[$0]?.isEmpty == false }),
              !arguments.contains(where: { argument in selectors.contains(where: argument.contains) }) else {
            throw CodexSignInError.unsupportedConfiguration
        }
    }

    private static func processConfiguration(_ pid: pid_t) throws -> ([String], [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            throw CodexSignInError.unsupportedConfiguration
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else {
            throw CodexSignInError.unsupportedConfiguration
        }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc < size else { throw CodexSignInError.unsupportedConfiguration }
        var cursor = 4
        func nextString() -> String {
            let start = cursor
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
            let result = String(decoding: bytes[start..<cursor], as: UTF8.self)
            if cursor < size { cursor += 1 }
            return result
        }
        _ = nextString() // Executable path, followed by alignment padding.
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard cursor < size else { throw CodexSignInError.unsupportedConfiguration }
            arguments.append(nextString())
        }
        var environment: [String: String] = [:]
        while cursor < size {
            let entry = nextString()
            if let equal = entry.firstIndex(of: "=") {
                environment[String(entry[..<equal])] = String(entry[entry.index(after: equal)...])
            }
        }
        return (arguments, environment)
    }

    @MainActor func close() async throws {
        try await validateConfiguration()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            throw CodexSignInError.appMissing
        }
        try Task.checkCancellation()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        var terminationStarted = false
        for app in apps where !app.isTerminated {
            guard app.terminate() else {
                if terminationStarted { throw CodexDesktopCloseError.terminationStarted }
                throw CodexSignInError.appCouldNotClose
            }
            terminationStarted = true
        }
        // Wait for bundled backend processes too; an exiting backend can still save refreshed auth.
        // Once termination is requested, finish this bounded wait even if our caller is cancelled.
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while apps.contains(where: { !$0.isTerminated }) || Self.hasBundledProcesses(url) {
            guard ContinuousClock.now < deadline else {
                if terminationStarted { throw CodexDesktopCloseError.terminationStarted }
                throw CodexSignInError.appCouldNotClose
            }
            await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
    }

    @MainActor func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            throw CodexSignInError.appMissing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if error == nil, app != nil { continuation.resume() }
                else { continuation.resume(throwing: CodexSignInError.reopenFailed) }
            }
        }
    }

    private static func hasBundledProcesses(_ appURL: URL) -> Bool {
        bundledProcesses(appURL)?.isEmpty != true
    }

    private static func bundledProcesses(_ appURL: URL) -> [pid_t]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
        let filled = proc_listallpids(&pids, bytes)
        guard filled >= 0 else { return nil }
        let prefix = appURL.resolvingSymlinksInPath().path + "/Contents/"
        var matching: [pid_t] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            // libproc's compound PROC_PIDPATHINFO_MAXSIZE macro is not imported into Swift.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                if String(decoding: bytes, as: UTF8.self).hasPrefix(prefix) { matching.append(pid) }
            }
        }
        return matching
    }
}
