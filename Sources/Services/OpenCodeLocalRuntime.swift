import AppKit
import Darwin
import Foundation

/// A verified local desktop backend, not the website or a selected remote server.
struct OpenCodeLocalRuntime: Sendable {
    let authURL: URL
    let v2: (any OpenCodeV2Serving)?
    let credentials: (any OpenCodeCredentialServing)?

    init(authURL: URL, v2: (any OpenCodeV2Serving)? = nil, credentials: (any OpenCodeCredentialServing)? = nil) {
        self.authURL = authURL
        self.v2 = v2
        self.credentials = credentials
    }

    static func discover() async throws -> Self {
        // ps/sysctl are blocking system calls; keep them off the main actor and
        // return only the few fields needed to verify this local backend.
        let desktops = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.openchamber.desktop")
                .reduce(into: [Int32: String]()) { apps, app in
                    apps[app.processIdentifier] = app.bundleURL?.resolvingSymlinksInPath().path
                }
        }
        let discovered = try await Task.detached { try discoverProcess(desktops: desktops) }.value
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration, delegate: OpenCodeNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: discovered.baseURL.appendingPathComponent("api/info"))
        request.setValue(discovered.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (infoData, infoResponse) = try await session.data(for: request)
            if try isV2Info(infoData, response: infoResponse, processID: discovered.pid) {
                return Self(authURL: discovered.authURL, v2: OpenCodeV2Client(
                    baseURL: discovered.baseURL, authorization: discovered.authorization
                ), credentials: OpenCodeCredentialClient(baseURL: discovered.baseURL, authorization: discovered.authorization))
            }
            // Only the old bundled CLI ever supported the V1 auth-file fallback.
            guard discovered.allowsLegacyHealth else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
            request.url = discovered.baseURL.appendingPathComponent("global/health")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let health = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  health["healthy"] as? Bool == true else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        } catch { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        return Self(authURL: discovered.authURL)
    }

    /// V1 serves HTML for unknown routes; a 200 alone is never evidence of V2.
    static func isV2Info(_ data: Data, response: URLResponse, processID: Int32) throws -> Bool {
        guard let http = response as? HTTPURLResponse else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        if http.statusCode == 404 { return false }
        guard http.statusCode == 200 else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        guard let info = try? JSONDecoder().decode(ServerInfo.self, from: data) else { return false }
        guard info.version.split(separator: ".").first == "2", info.pid == processID else {
            throw OpenCodeOpenAIAuthError.runtimeUnavailable
        }
        return true
    }

    private struct ServerInfo: Decodable {
        let version: String
        let pid: Int32
    }

    static func authURL(environment: [String: String]) throws -> URL {
        for key in ["OPENCODE_AUTH_CONTENT", "OPENCODE_DATA_DIR", "OPENCODE_DB"] where !(environment[key] ?? "").isEmpty {
            throw OpenCodeOpenAIAuthError.environmentOverride
        }
        guard let home = environment["HOME"], home.hasPrefix("/") else {
            throw OpenCodeOpenAIAuthError.runtimeUnavailable
        }
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        guard dataHome.hasPrefix("/") else { throw OpenCodeOpenAIAuthError.environmentOverride }
        return URL(fileURLWithPath: dataHome, isDirectory: true).appendingPathComponent("opencode/auth.json")
    }

    struct ProcessLocation: Sendable {
        let pid: Int32
        let authURL: URL
        let baseURL: URL
        let authorization: String?
        let allowsLegacyHealth: Bool
    }

    struct Registration: Decodable {
        let pid: Int32
        let ownerPid: Int32
        let runtime: String
        let port: Int
    }

    private static func discoverProcess(desktops: [Int32: String]) throws -> ProcessLocation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/openchamber/managed-opencode", isDirectory: true)
        return try locate(processTable: String(decoding: data, as: UTF8.self), desktops: desktops, registration: { pid in
            let url = registry.appendingPathComponent("\(pid).json")
            do { return try JSONDecoder().decode(Registration.self, from: Data(contentsOf: url)) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            catch { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        }, argumentsForPID: processArguments)
    }

    /// The registry is a hint, not authority to connect: the OS must put the child inside
    /// the owning desktop bundle, its launch port must agree, and /api/info must echo its PID.
    static func locate(processTable: String, desktops: [Int32: String],
                       registration: (Int32) throws -> Registration?,
                       argumentsForPID: (Int32) throws -> ([String], [String: String])) throws -> ProcessLocation {
        var candidates: [(pid: Int32, port: Int?, legacy: Bool)] = []
        var cliPIDs: [Int32] = []
        for line in processTable.split(separator: "\n") {
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { continue }
            let path = String(parts[2]).trimmingCharacters(in: .whitespaces)
            let legacy = path.hasSuffix("/OpenChamber.app/Contents/Resources/opencode-cli/opencode")
            if path.hasSuffix("/opencode") { cliPIDs.append(pid) }
            if let bundle = desktops[parent], path.hasPrefix(bundle + "/Contents/"),
               let record = try registration(pid) {
                guard record.runtime == "desktop", record.pid == pid, record.ownerPid == parent else {
                    throw OpenCodeOpenAIAuthError.runtimeUnavailable
                }
                candidates.append((pid, record.port, legacy))
            } else if legacy {
                candidates.append((pid, nil, true))
            }
        }
        guard let selected = candidates.first else {
            throw desktops.isEmpty ? OpenCodeOpenAIAuthError.localInstanceRequired : .runtimeUnavailable
        }
        guard candidates.count == 1 else { throw OpenCodeOpenAIAuthError.ambiguousInstance }
        let (arguments, environment) = try argumentsForPID(selected.pid)
        let auth = try authURL(environment: environment)
        for other in cliPIDs where other != selected.pid {
            let (_, otherEnvironment) = try argumentsForPID(other)
            if try authURL(environment: otherEnvironment) == auth { throw OpenCodeOpenAIAuthError.ambiguousInstance }
        }
        func argument(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("serve"),
              ["127.0.0.1", "localhost", "::1"].contains(argument("--hostname") ?? ""),
              let portText = argument("--port"), let port = Int(portText), (1...65535).contains(port),
              selected.port == nil || selected.port == port else {
            throw OpenCodeOpenAIAuthError.runtimeUnavailable
        }
        var components = URLComponents()
        components.scheme = "http"
        let host = argument("--hostname")
        components.host = host == "::1" ? "[::1]" : host
        components.port = port
        guard let baseURL = components.url else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        let authorization = environment["OPENCODE_SERVER_PASSWORD"].map {
            "Basic " + Data("\(environment["OPENCODE_SERVER_USERNAME"] ?? "opencode"):\($0)".utf8).base64EncodedString()
        }
        return ProcessLocation(pid: selected.pid, authURL: auth, baseURL: baseURL, authorization: authorization,
                               allowsLegacyHealth: selected.legacy)
    }

    /// KERN_PROCARGS2 preserves argument boundaries and paths with spaces, unlike ps eww.
    private static func processArguments(pid: Int32) throws -> ([String], [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            throw OpenCodeOpenAIAuthError.runtimeUnavailable
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > MemoryLayout<Int32>.size else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 10000 else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        var cursor = MemoryLayout<Int32>.size
        func nextString() -> String {
            let start = cursor
            while cursor < size && bytes[cursor] != 0 { cursor += 1 }
            let value = String(decoding: bytes[start..<cursor], as: UTF8.self)
            if cursor < size { cursor += 1 }
            return value
        }
        _ = nextString() // executable path, followed by padding
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        let arguments = (0..<count).map { _ in nextString() }
        let keys: Set<String> = ["HOME", "XDG_DATA_HOME", "OPENCODE_DATA_DIR", "OPENCODE_DB", "OPENCODE_AUTH_CONTENT",
                                 "OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_USERNAME"]
        var environment: [String: String] = [:]
        while cursor < size {
            let value = nextString()
            guard let equals = value.firstIndex(of: "=") else { continue }
            let key = String(value[..<equals])
            if keys.contains(key) { environment[key] = String(value[value.index(after: equals)...]) }
        }
        return (arguments, environment)
    }
}

final class OpenCodeNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
