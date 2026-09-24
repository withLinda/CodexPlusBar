import Darwin
import Foundation

/// A verified local desktop backend, not the website or a selected remote server.
struct OpenCodeLocalRuntime: Sendable {
    let authURL: URL
    let v2: (any OpenCodeV2Serving)?

    init(authURL: URL, v2: (any OpenCodeV2Serving)? = nil) {
        self.authURL = authURL
        self.v2 = v2
    }

    static func discover() async throws -> Self {
        // ps/sysctl are blocking system calls; keep them off the main actor and
        // return only the few fields needed to verify this local backend.
        let discovered = try await Task.detached { try discoverProcess() }.value
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
                ))
            }
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

    private struct ProcessLocation: Sendable {
        let pid: Int32
        let authURL: URL
        let baseURL: URL
        let authorization: String?
    }

    private static func discoverProcess() throws -> ProcessLocation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, String)? in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            let command = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard URL(fileURLWithPath: command).lastPathComponent == "opencode" else { return nil }
            return (pid, command)
        }
        let managed = rows.filter { $0.1.hasSuffix("OpenChamber.app/Contents/Resources/opencode-cli/opencode") }
        guard !managed.isEmpty else { throw OpenCodeOpenAIAuthError.localInstanceRequired }
        guard managed.count == 1 else { throw OpenCodeOpenAIAuthError.ambiguousInstance }
        let (arguments, environment) = try processArguments(pid: managed[0].0)
        let auth = try authURL(environment: environment)
        for other in rows where other.0 != managed[0].0 {
            let (_, otherEnvironment) = try processArguments(pid: other.0)
            if try authURL(environment: otherEnvironment) == auth { throw OpenCodeOpenAIAuthError.ambiguousInstance }
        }
        func argument(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("serve"),
              ["127.0.0.1", "localhost", "::1"].contains(argument("--hostname") ?? ""),
              let portText = argument("--port"), let port = Int(portText), (1...65535).contains(port) else {
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
        return ProcessLocation(pid: managed[0].0, authURL: auth, baseURL: baseURL, authorization: authorization)
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
