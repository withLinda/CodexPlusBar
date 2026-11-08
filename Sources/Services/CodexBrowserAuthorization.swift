import AppKit
import Darwin
import Foundation

/// Uses the desktop's own PKCE/callback implementation in an isolated home.
struct CodexBrowserAuthorization: AppSignInAuthorizing {
    var executable: URL? = nil
    var timeout: Duration = .seconds(300)
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    static func validateURL(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "auth.openai.com",
              components.port == nil || components.port == 443, components.user == nil, components.password == nil,
              components.path == "/oauth/authorize", components.fragment == nil else { throw AppSignInRepairError.invalidAuthorization }
        let items = components.queryItems ?? []
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("client_id") == "app_EMoamEEZ73f0CkXaXp7hrann", single("response_type") == "code",
              single("code_challenge_method") == "S256", single("code_challenge")?.isEmpty == false,
              single("state")?.isEmpty == false,
              ["http://127.0.0.1:1455/auth/callback", "http://127.0.0.1:1457/auth/callback",
               "http://localhost:1455/auth/callback"].contains(single("redirect_uri") ?? "") else {
            throw AppSignInRepairError.invalidAuthorization
        }
    }

    func authorize(profile: PlusProfile, openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> CodexSignIn {
        try await CodexLoginProcess.authorize(executable: executable, timeout: timeout, profile: profile,
                                             directory: recoveryDirectory(profile), openURL: openURL)
    }

    func acknowledge(_ signIn: CodexSignIn, profile: PlusProfile) async throws {
        let directory = recoveryDirectory(profile), file = directory.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let recovered = try CodexSignIn(data: Data(contentsOf: file))
        if recovered == signIn { try FileManager.default.removeItem(at: directory) }
    }

    private func recoveryDirectory(_ profile: PlusProfile) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/CodexPlusBar/AppSignInRepairs/Authorizations/\(profile.id.uuidString)")
    }
}

@MainActor
private final class CodexLoginProcess {
    private static var busy = false
    let process = Process()
    let input = Pipe(), output = Pipe()
    let stream: AsyncStream<Data>
    let continuation: AsyncStream<Data>.Continuation
    var timedOut = false
    var loginID: String?
    var earlyCompletions: [LoginMessage] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    static func authorize(executable override: URL?, timeout: Duration, profile: PlusProfile,
                          directory: URL,
                          openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> CodexSignIn {
        try Task.checkCancellation()
        guard !busy else { throw AppSignInRepairError.loginBusy }
        busy = true; defer { busy = false }
        let authFile = directory.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: authFile.path) {
            if let saved = try? CodexSignIn(data: Data(contentsOf: authFile)),
               (try? saved.validateRepair(for: profile)) != nil { return saved }
            try FileManager.default.removeItem(at: directory)
        }
        let executable: URL
        if let override { executable = override }
        else {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexDesktopApp.bundleIdentifier) else {
                throw AppSignInRepairError.helperUnavailable
            }
            let candidates = ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"]
            guard let found = candidates.map({ app.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw AppSignInRepairError.helperUnavailable
            }
            executable = found
        }
        try requireAvailablePorts()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer {
            // Keep a valid grant until the coordinator confirms its private-store handoff.
            // A crash or disk-full error must not force another authorization.
            if let data = try? Data(contentsOf: authFile), let saved = try? CodexSignIn(data: data),
               (try? saved.validateRepair(for: profile)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
            } else { try? FileManager.default.removeItem(at: directory) }
        }
        let runner = CodexLoginProcess()
        runner.process.executableURL = executable
        runner.process.arguments = ["app-server", "-c", "cli_auth_credentials_store=\"file\""]
        runner.process.currentDirectoryURL = directory
        runner.process.environment = ["HOME": directory.path, "CFFIXED_USER_HOME": directory.path,
            "CODEX_HOME": directory.path, "TMPDIR": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "RUST_LOG": "off"]
        runner.process.standardInput = runner.input
        runner.process.standardOutput = runner.output
        runner.process.standardError = FileHandle.nullDevice
        let continuation = runner.continuation
        runner.output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() } else { continuation.yield(data) }
        }
        do { try runner.process.run() }
        catch { runner.stop(); throw AppSignInRepairError.helperUnavailable }
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            runner.timedOut = true; runner.stop()
        }
        defer { deadline.cancel(); runner.stop() }
        return try await withTaskCancellationHandler {
            do {
                let reader = LoginOutputReader(stream: runner.stream)
                try runner.send(id: 1, method: "initialize", params: ["clientInfo": ["name": "codexplusbar", "version": "1.0"]])
                _ = try await runner.response(id: 1, reader: reader)
                try runner.send(id: nil, method: "initialized", params: nil)
                try requireAvailablePorts()
                try runner.send(id: 2, method: "account/login/start", params: ["type": "chatgpt"])
                let response = try await runner.response(id: 2, reader: reader)
                guard response.type == "chatgpt", let id = response.loginId, !id.isEmpty,
                      let raw = response.authUrl, let url = URL(string: raw) else { throw AppSignInRepairError.invalidAuthorization }
                try CodexBrowserAuthorization.validateURL(url)
                runner.loginID = id
                try await openURL(url)
                while true {
                    let message = runner.earlyCompletions.isEmpty ? try await reader.next() : runner.earlyCompletions.removeFirst()
                    guard message.method == "account/login/completed", let params = message.params, params.loginId == id else { continue }
                    guard params.success == true else { throw AppSignInRepairError.denied }
                    let signIn = try CodexSignIn(data: Data(contentsOf: directory.appendingPathComponent("auth.json")))
                    try signIn.validateRepair(for: profile)
                    return signIn
                }
            } catch {
                // Completion can reach the private auth file before its event/cancellation.
                // Stop the writer before salvaging a completed matching grant.
                runner.stop()
                if let data = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
                   let signIn = try? CodexSignIn(data: data), (try? signIn.validateRepair(for: profile)) != nil { return signIn }
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if runner.timedOut { throw AppSignInRepairError.timedOut }
                if error is AppSignInRepairError { throw error }
                throw AppSignInRepairError.helperFailed
            }
        } onCancel: { Task { @MainActor in runner.stop() } }
    }

    private func send(id: Int?, method: String, params: [String: Any]?) throws {
        var message: [String: Any] = ["method": method]
        if let id { message["id"] = id }
        if let params { message["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func response(id: Int, reader: LoginOutputReader) async throws -> LoginMessage.Payload {
        while true {
            let message = try await reader.next()
            guard message.id == id else {
                if message.method == "account/login/completed" {
                    guard earlyCompletions.count < 16 else { throw AppSignInRepairError.helperFailed }
                    earlyCompletions.append(message)
                }
                continue
            }
            guard let result = message.result else { throw AppSignInRepairError.helperFailed }
            return result
        }
    }
    private func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        continuation.finish()
        if process.isRunning {
            // Only our isolated helper is terminated; no live desktop process is touched.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
    private static func requireAvailablePorts() throws {
        for port: UInt16 in [1455, 1457] {
            // Darwin permits a reusable loopback bind beside a wildcard
            // listener, so probe both exact addresses without connecting.
            for host in ["127.0.0.1", "0.0.0.0"] {
                try requireAvailablePort(port, host: host)
            }
        }
    }

    private static func requireAvailablePort(_ port: UInt16, host: String) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppSignInRepairError.loginBusy }
        defer { close(descriptor) }
        // Match the helper's TCP listener: a completed browser callback can
        // remain in TIME_WAIT after the helper exits. That is not an active
        // login. SO_REUSEADDR allows this cleanup state while still rejecting
        // a live listener; never enable SO_REUSEPORT or contact its /cancel.
        var reuseAddress: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw AppSignInRepairError.loginBusy
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw AppSignInRepairError.loginBusy }
    }
}

private struct LoginMessage: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        var type: String?
        var loginId: String?
        var authUrl: String?
        var success: Bool?
    }
    var id: Int?
    var method: String?
    var result: Payload?
    var params: Payload?
}

/// Exactly one awaited consumer owns this iterator. Keeping it nonisolated supports
/// macOS 14's AsyncIterator API; the stream producer touches only its continuation.
private final class LoginOutputReader: @unchecked Sendable {
    private var iterator: AsyncStream<Data>.Iterator
    private var buffered = Data()
    init(stream: AsyncStream<Data>) { iterator = stream.makeAsyncIterator() }
    func next() async throws -> LoginMessage {
        while true {
            if let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
                return try JSONDecoder().decode(LoginMessage.self, from: line)
            }
            guard let chunk = await iterator.next() else { throw AppSignInRepairError.helperFailed }
            guard buffered.count + chunk.count <= 1_048_576 else { throw AppSignInRepairError.helperFailed }
            buffered.append(chunk)
        }
    }
}
