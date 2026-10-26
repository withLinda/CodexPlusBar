import Foundation

enum OpenCodeCredentialError: LocalizedError, Equatable {
    case unavailable, invalidResponse, unsupportedMethod
    var errorDescription: String? {
        switch self {
        case .unavailable: "OpenChamber’s native account service is unavailable. Open a supported local OpenChamber instance."
        case .invalidResponse: "OpenChamber’s account list could not be verified. Sync will retry."
        case .unsupportedMethod: "An OpenChamber sign-in uses an unsupported login method. Automatic removal is paused."
        }
    }
}

struct OpenCodeCredentialValue: Codable, Equatable, Sendable {
    enum JSON: Codable, Equatable, Sendable {
        case string(String), number(Decimal), bool(Bool), object([String: JSON]), array([JSON]), null
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode(Decimal.self) { self = .number(v) }
            else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
            else { self = .array(try c.decode([JSON].self)) }
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }
        var string: String? { if case .string(let v) = self { v } else { nil } }
    }
    var fields: [String: JSON]
    init(fields: [String: JSON]) { self.fields = fields }
    init(from decoder: any Decoder) throws { fields = try decoder.singleValueContainer().decode([String: JSON].self) }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(fields) }
    var type: String? { fields["type"]?.string }
    var methodID: String? { fields["methodID"]?.string }

    func auth() throws -> OpenCodeOpenAIAuth {
        guard type == "oauth", ["chatgpt-browser", "chatgpt-headless"].contains(methodID) else {
            throw OpenCodeCredentialError.unsupportedMethod
        }
        guard let access = fields["access"]?.string, let refresh = fields["refresh"]?.string,
              case .number(let expires) = fields["expires"], expires >= 0,
              let milliseconds = Int64(NSDecimalNumber(decimal: expires).stringValue),
              case .object(let metadata) = fields["metadata"], let accountID = metadata["accountID"]?.string else {
            throw OpenCodeCredentialError.invalidResponse
        }
        let value = OpenCodeOpenAIAuth(type: "oauth", refresh: refresh, access: access, expires: milliseconds, accountId: accountID)
        _ = try value.identity()
        return value
    }

    static func legacy(_ auth: OpenCodeOpenAIAuth) -> Self {
        Self(fields: ["type": .string("oauth"), "methodID": .string("chatgpt-browser"), "access": .string(auth.access),
                      "refresh": .string(auth.refresh), "expires": .number(Decimal(auth.expires)),
                      "metadata": .object(["accountID": .string(auth.accountId)])])
    }
    func replacingTokens(_ auth: OpenCodeOpenAIAuth) -> Self {
        var result = self
        result.fields["access"] = .string(auth.access)
        result.fields["refresh"] = .string(auth.refresh)
        result.fields["expires"] = .number(Decimal(auth.expires))
        return result
    }
}

struct OpenCodeStoredCredential: Codable, Equatable, Sendable {
    let id: String
    let integrationID: String
    var label: String
    var active: Bool
    var value: OpenCodeCredentialValue
    func openAIIdentity() throws -> OpenCodeOpenAIIdentity {
        guard integrationID == "openai" else { throw OpenCodeCredentialError.invalidResponse }
        return try value.auth().identity()
    }
}

struct OpenCodeCredentialInventory: Sendable {
    let entries: [OpenCodeStoredCredential]
    let connectionIDs: Set<String>
    var openAI: [OpenCodeStoredCredential] { entries.filter { $0.integrationID == "openai" } }
    var oauth: [OpenCodeStoredCredential] { openAI.filter { $0.value.type == "oauth" } }
}

protocol OpenCodeCredentialServing: Sendable {
    func inventory() async throws -> OpenCodeCredentialInventory
    func create(id: String, label: String, value: OpenCodeCredentialValue, activate: Bool) async throws -> OpenCodeStoredCredential
    func rename(id: String, label: String) async throws
    func activate(id: String) async throws
    func remove(id: String) async throws
    func hasRunningSessions() async throws -> Bool
}

actor OpenCodeCredentialClient: OpenCodeCredentialServing {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let baseURL: URL
    private let authorization: String?
    private let directory: String
    private let request: Request
    private let session: URLSession?
    private var checkedCapabilities = false

    init(baseURL: URL, authorization: String?, directory: String = NSHomeDirectory(), request: Request? = nil) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.directory = directory
        if let request { self.request = request; session = nil }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]; config.httpCookieStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config, delegate: OpenCodeNoRedirect(), delegateQueue: nil)
            self.session = session
            self.request = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw OpenCodeCredentialError.invalidResponse }
                return (data, http)
            }
        }
    }
    deinit { session?.invalidateAndCancel() }

    func inventory() async throws -> OpenCodeCredentialInventory {
        try await capabilities()
        let integration: Envelope<Integration> = try await get("api/integration/openai")
        let credentials: Envelope<[OpenCodeStoredCredential]> = try await get("api/credential")
        guard integration.data.id == "openai" else { throw OpenCodeCredentialError.invalidResponse }
        let ids = try integration.data.connections.filter { $0.type == "credential" }.map {
            guard let id = $0.id else { throw OpenCodeCredentialError.invalidResponse }
            try Self.validate(id); return id
        }
        let entries = credentials.data
        guard Set(ids).count == ids.count, Set(entries.map(\.id)).count == entries.count,
              Set(entries.filter { $0.integrationID == "openai" }.map(\.id)) == Set(ids),
              entries.filter({ $0.integrationID == "openai" && $0.active }).count <= 1 else {
            throw OpenCodeCredentialError.invalidResponse
        }
        for entry in entries { try Self.validate(entry.id) }
        return OpenCodeCredentialInventory(entries: entries, connectionIDs: Set(ids))
    }

    func create(id: String, label: String, value: OpenCodeCredentialValue, activate: Bool) async throws -> OpenCodeStoredCredential {
        try Self.validate(id)
        _ = try value.auth()
        let data = try await send("api/credential", method: "POST", body: JSONEncoder().encode(Create(id: id, label: label, value: value, activate: activate)), status: 200)
        let result = try decode(Envelope<OpenCodeStoredCredential>.self, data).data
        guard result.id == id, result.integrationID == "openai" else { throw OpenCodeCredentialError.invalidResponse }
        return result
    }
    func rename(id: String, label: String) async throws {
        try Self.validate(id)
        _ = try await send("api/credential/\(id)", method: "PATCH", body: JSONEncoder().encode(["label": label]), status: 204)
    }
    func activate(id: String) async throws {
        try Self.validate(id)
        _ = try await send("api/credential/\(id)/activate", method: "POST", body: Data("{}".utf8), status: 204)
    }
    func remove(id: String) async throws {
        try Self.validate(id)
        _ = try await send("api/credential/\(id)", method: "DELETE", status: 204)
    }
    func hasRunningSessions() async throws -> Bool {
        let result: Envelope<[String: Running]> = try await get("api/session/active")
        guard result.data.allSatisfy({ $0.key.hasPrefix("ses") && $0.value.type == "running" }) else { throw OpenCodeCredentialError.invalidResponse }
        return !result.data.isEmpty
    }
    private func capabilities() async throws {
        guard !checkedCapabilities else { return }
        let data = try await send("openapi.json")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = root["paths"] as? [String: Any], let route = paths["/api/credential"] as? [String: Any],
              route["get"] != nil, route["post"] != nil,
              let components = root["components"] as? [String: Any], let schemas = components["schemas"] as? [String: Any],
              let create = schemas["Credential.CreateInput"] as? [String: Any], let properties = create["properties"] as? [String: Any],
              properties["value"] != nil, properties["activate"] != nil, properties["integrationID"] != nil else {
            throw OpenCodeCredentialError.unavailable
        }
        checkedCapabilities = true
    }
    private static func validate(_ id: String) throws {
        guard id.hasPrefix("cred_"), id.count > 5, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw OpenCodeCredentialError.invalidResponse
        }
    }
    private func get<T: Decodable>(_ path: String) async throws -> T { try decode(T.self, await send(path)) }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw OpenCodeCredentialError.invalidResponse }
        return value
    }
    private func send(_ path: String, method: String = "GET", body: Data? = nil, status: Int = 200) async throws -> Data {
        try Task.checkCancellation()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method; req.httpBody = body
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        do {
            let (data, response) = try await request(req)
            guard response.statusCode == status else { throw OpenCodeCredentialError.unavailable }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as OpenCodeCredentialError { throw error }
        catch { throw OpenCodeCredentialError.unavailable }
    }
    private struct Envelope<T: Decodable>: Decodable { let data: T }
    private struct Integration: Decodable {
        let id: String
        let connections: [Connection]
        struct Connection: Decodable { let type: String; let id: String? }
    }
    private struct Running: Decodable { let type: String }
    private struct Create: Encodable {
        let id: String
        let integrationID = "openai"
        let label: String
        let value: OpenCodeCredentialValue
        let activate: Bool
    }
}
