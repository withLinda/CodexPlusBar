import Foundation
import Testing
@testable import CodexPlusBar

struct OpenCodeCredentialClientTests {
    @Test func nativeCreatePreservesMethodAndMetadata() async throws {
        let entry = try nativeCredential("alpha")
        let client = OpenCodeCredentialClient(baseURL: URL(string: "http://127.0.0.1:1234")!, authorization: "Basic fixture", request: { request in
            #expect(request.url?.path == "/api/credential")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic fixture")
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
            #expect(body["activate"] as? Bool == false)
            #expect(body["integrationID"] as? String == "openai")
            let value = try #require(body["value"] as? [String: Any])
            #expect(value["methodID"] as? String == "chatgpt-headless")
            #expect((value["metadata"] as? [String: Any])?["extra"] as? String == "retained")
            return (try JSONEncoder().encode(NativeEnvelope(data: entry)), nativeResponse(request, 200))
        })
        let result = try await client.create(id: entry.id, label: entry.label, value: entry.value, activate: false)
        #expect(result == entry)
    }

    @Test func identityDistinguishesSameEmailDifferentWorkspace() throws {
        let a = try nativeCredential("alpha", email: "same@example.com")
        let b = try nativeCredential("beta", email: "same@example.com")
        #expect(try a.openAIIdentity().matches(b.openAIIdentity()) == false)
    }

    @Test func unknownMethodNeverBecomesAbsentAccount() throws {
        var a = try nativeCredential("alpha")
        a.value.fields["methodID"] = .string("future-method")
        #expect(throws: OpenCodeCredentialError.unsupportedMethod) { try a.openAIIdentity() }
    }

    @Test(arguments: ["<html>app</html>", "{\"data\":[]}"])
    func inventoryRejectsIncompleteOrHTMLResponses(_ body: String) async {
        let client = OpenCodeCredentialClient(baseURL: URL(string: "http://127.0.0.1:1234")!, authorization: nil, request: { request in
            (Data(body.utf8), nativeResponse(request, 200))
        })
        await #expect(throws: (any Error).self) { try await client.inventory() }
    }

    @Test func inventoryPreservesCurrentRotatedValue() async throws {
        var entry = try nativeCredential("alpha")
        entry.value.fields["refresh"] = .string("rotated-fixture")
        let expected = entry
        let client = OpenCodeCredentialClient(baseURL: URL(string: "http://127.0.0.1:1234")!, authorization: nil, request: { request in
            let data: Data
            switch request.url?.path {
            case "/openapi.json": data = nativeCapabilityFixture()
            case "/api/integration/openai": data = Data("{\"data\":{\"id\":\"openai\",\"connections\":[{\"type\":\"credential\",\"id\":\"cred_alpha\"}]}}".utf8)
            default: data = try JSONEncoder().encode(NativeEnvelope(data: [expected]))
            }
            return (data, nativeResponse(request, 200))
        })
        let inventory = try await client.inventory()
        #expect(inventory.entries == [expected])
    }

    @Test func pathsUseEncodedCredentialIDs() async {
        let client = OpenCodeCredentialClient(baseURL: URL(string: "http://127.0.0.1:1234")!, authorization: nil, request: { _ in
            Issue.record("Invalid ID must not send a request")
            throw URLError(.badURL)
        })
        await #expect(throws: OpenCodeCredentialError.invalidResponse) { try await client.remove(id: "cred_a/../other") }
    }

    @Test(arguments: [false, true]) func activeSessionsDecodeRunningMap(_ running: Bool) async throws {
        let client = OpenCodeCredentialClient(baseURL: URL(string: "http://127.0.0.1:1234")!, authorization: nil, request: { request in
            #expect(request.url?.path == "/api/session/active")
            return (Data((running ? "{\"data\":{\"ses_fixture\":{\"type\":\"running\"}}}" : "{\"data\":{}}").utf8), nativeResponse(request, 200))
        })
        #expect(try await client.hasRunningSessions() == running)
    }
}

struct NativeEnvelope<T: Codable>: Codable { let data: T }

func nativeCredential(_ name: String, email: String? = nil, active: Bool = false) throws -> OpenCodeStoredCredential {
    let claims: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": name, "chatgpt_user_id": "user-" + name],
                               "https://api.openai.com/profile": ["email": email ?? name + "@example.com"]]
    let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let data = try JSONSerialization.data(withJSONObject: ["type": "oauth", "methodID": "chatgpt-headless", "access": "fixture.\(payload).sig",
                                                         "refresh": "refresh-\(name)", "expires": 4_000_000_000_000,
                                                         "metadata": ["accountID": name, "extra": "retained"]])
    return OpenCodeStoredCredential(id: "cred_" + name, integrationID: "openai", label: email ?? name + "@example.com", active: active,
                                    value: try JSONDecoder().decode(OpenCodeCredentialValue.self, from: data))
}

func nativeResponse(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
}

func nativeCapabilityFixture() -> Data {
    Data(##"{"paths":{"/api/credential":{"get":{"responses":{"200":{}}},"post":{"requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Credential.CreateInput"}}}}}}},"components":{"schemas":{"Credential.CreateInput":{"properties":{"value":{},"activate":{},"integrationID":{}}}}}}"##.utf8)
}
