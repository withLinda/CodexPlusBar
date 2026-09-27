import Foundation

struct OpenCodeV2Credential: Codable, Equatable, Sendable {
    let id: String
    let auth: OpenCodeOpenAIAuth
}

protocol OpenCodeV2Serving: Sendable {
    func read(id: String?) async throws -> OpenCodeV2Credential
    func install(_ auth: OpenCodeOpenAIAuth, expected: OpenCodeV2Credential) async throws -> OpenCodeV2Credential
    func activate(_ credential: OpenCodeV2Credential, expected: OpenCodeV2Credential) async throws -> OpenCodeV2Credential
}

/// V2 has no HTTP credential import/export route. A location-scoped plugin uses
/// the public integration API; no direct database writes or global config edits.
actor OpenCodeV2Client: OpenCodeV2Serving {
    private let baseURL: URL
    private let authorization: String?
    private let directory: URL
    private let session: URLSession
    private var installed = false

    init(baseURL: URL, authorization: String?, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.baseURL = baseURL
        self.authorization = authorization
        directory = homeDirectory.appendingPathComponent("Library/Application Support/CodexPlusBar/OpenChamberBridge-v1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: OpenCodeNoRedirect(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func read(id: String? = nil) async throws -> OpenCodeV2Credential {
        try installBridge()
        if let id {
            // The bridge deliberately hides internal errors. Confirm absence
            // through the public API instead of treating every RPC 500 as a
            // deleted connection (or every deleted connection as an outage).
            let data = try await send(path: "api/integration/openai", body: nil, status: 200)
            try Self.requireConnection(id, in: data)
        }
        return try await rpc("read", input: ReadInput(id: id))
    }

    static func requireConnection(_ id: String, in data: Data) throws {
        guard let integration = try? JSONDecoder().decode(IntegrationOutput.self, from: data).data,
              integration.id == "openai",
              integration.connections.allSatisfy({ $0.type != "credential" || isCredentialID($0.id) }) else {
            throw OpenCodeOpenAIAuthError.bridgeUnavailable
        }
        guard integration.connections.contains(where: { $0.type == "credential" && $0.id == id }) else {
            throw OpenCodeOpenAIAuthError.credentialNotFound
        }
    }

    private static func isCredentialID(_ id: String?) -> Bool {
        guard let id, id.hasPrefix("cred_"), id.count > 5 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    func install(_ auth: OpenCodeOpenAIAuth, expected: OpenCodeV2Credential) async throws -> OpenCodeV2Credential {
        try installBridge()
        _ = try auth.identity()
        return try await rpc("import", input: ImportInput(auth: auth, expected: expected))
    }

    func activate(_ credential: OpenCodeV2Credential, expected: OpenCodeV2Credential) async throws -> OpenCodeV2Credential {
        guard try await read() == expected else { throw OpenCodeOpenAIAuthError.changedWhileReading }
        // Resolve only known OpenAI connections; never activate another provider.
        let target = try await read(id: credential.id)
        guard try target.auth.identity().matches(credential.auth.identity()) else {
            throw OpenCodeOpenAIAuthError.identityMismatch
        }
        _ = try await send(path: "api/credential/\(target.id)/activate", body: Data("{}".utf8), status: 204)
        let current = try await read()
        guard current.id == target.id else { throw OpenCodeOpenAIAuthError.changedWhileReading }
        return current
    }

    private struct ReadInput: Encodable { let id: String? }
    private struct ImportInput: Encodable { let auth: OpenCodeOpenAIAuth; let expected: OpenCodeV2Credential }
    private struct Input<Value: Encodable>: Encodable { let input: Value }
    private struct Output: Decodable { let output: OpenCodeV2Credential }
    private struct IntegrationOutput: Decodable {
        let data: Integration
        struct Integration: Decodable {
            let id: String
            let connections: [Connection]
        }
        struct Connection: Decodable {
            let type: String
            let id: String?
        }
    }

    private func rpc<Value: Encodable>(_ method: String, input: Value) async throws -> OpenCodeV2Credential {
        let data = try await send(path: "api/rpc/codexplusbar.openai/\(method)",
                                  body: JSONEncoder().encode(Input(input: input)), status: 200)
        guard let value = try? JSONDecoder().decode(Output.self, from: data).output,
              Self.isCredentialID(value.id) else {
            throw OpenCodeOpenAIAuthError.bridgeUnavailable
        }
        _ = try value.auth.identity()
        return value
    }

    private func send(path: String, body: Data?, status: Int) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(directory.path, forHTTPHeaderField: "x-opencode-directory")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == status else {
            throw OpenCodeOpenAIAuthError.bridgeUnavailable
        }
        return data
    }

    private func installBridge() throws {
        guard !installed else { return }
        guard let resource = Bundle.main.url(forResource: "codexplusbar-openchamber-v2", withExtension: "mjs") else {
            throw OpenCodeOpenAIAuthError.bridgeUnavailable
        }
        do {
            let plugins = directory.appendingPathComponent(".opencode/plugins")
            try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let destination = plugins.appendingPathComponent("codexplusbar.js")
            let data = try Data(contentsOf: resource)
            if (try? Data(contentsOf: destination)) != data {
                try OpenCodePrivateFile.write(data, to: destination)
            }
            installed = true
        } catch { throw OpenCodeOpenAIAuthError.bridgeUnavailable }
    }
}
