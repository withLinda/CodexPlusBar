import Foundation
import Testing
@testable import CodexPlusBar

struct OpenCodeV2Tests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCHAMBER_V2_TEST_URL"] != nil))
    func isolatedServerSwitchesThroughProductionClient() async throws {
        let rawURL = try #require(ProcessInfo.processInfo.environment["OPENCHAMBER_V2_TEST_URL"])
        let url = try #require(URL(string: rawURL))
        #expect(url.host == "127.0.0.1")
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let target = try fixture.auth("swift-target")
        let profile = try await fixture.prepareTarget(target)
        let legacy = try Data(contentsOf: fixture.authURL)
        let client = OpenCodeV2Client(baseURL: url,
                                     authorization: "Basic " + Data("opencode:fixture-password".utf8).base64EncodedString(),
                                     homeDirectory: fixture.home)
        let original = try await client.read()
        let runtime = OpenCodeLocalRuntime(authURL: fixture.authURL, v2: client)
        let service = OpenCodeOpenAIAuthService(homeDirectory: fixture.home, resolveRuntime: { runtime },
                                               verifier: V2TestVerifier(), now: { OpenCodeAuthFixture.now })
        var originalProfile = fixture.profile("original")
        originalProfile.label = try original.auth.identity().email
        originalProfile.openCodeOpenAIAccount = try await service.saveCurrent(for: originalProfile)
        try await service.switchTo(profile: profile)
        #expect(try await client.read().auth == target)
        try await service.switchTo(profile: originalProfile)
        #expect(try await client.read().id == original.id)
        #expect(try Data(contentsOf: fixture.authURL) == legacy)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCHAMBER_V2_BRIDGE_PROBE"] == "1"))
    func installedV2BridgeCanReadCurrentConnection() async throws {
        let runtime = try await OpenCodeLocalRuntime.discover()
        let client = try #require(runtime.v2)
        let legacy = try? Data(contentsOf: runtime.authURL)
        let current = try await client.read(id: nil)
        #expect(current.id.hasPrefix("cred_"))
        #expect(try !current.auth.identity().accountID.isEmpty)
        #expect(try await client.read(id: current.id).id == current.id)
        #expect((try? Data(contentsOf: runtime.authURL)) == legacy)
    }

    @Test func discoveryRequiresV2IdentityAndMatchingProcess() throws {
        let url = try #require(URL(string: "http://127.0.0.1:4096/api/info"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        #expect(try OpenCodeLocalRuntime.isV2Info(Data(#"{"version":"2.0.15","pid":123}"#.utf8), response: response, processID: 123))
        #expect(try !OpenCodeLocalRuntime.isV2Info(Data("<!doctype html><title>OpenCode</title>".utf8), response: response, processID: 123))
        for body in [#"{"version":"2.0.15","pid":456}"#, #"{"version":"3.0.0","pid":123}"#] {
            #expect(throws: OpenCodeOpenAIAuthError.runtimeUnavailable) {
                try OpenCodeLocalRuntime.isV2Info(Data(body.utf8), response: response, processID: 123)
            }
        }
        let denied = try #require(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
        #expect(throws: OpenCodeOpenAIAuthError.runtimeUnavailable) {
            try OpenCodeLocalRuntime.isV2Info(Data(), response: denied, processID: 123)
        }
        #expect(throws: OpenCodeOpenAIAuthError.environmentOverride) {
            try OpenCodeLocalRuntime.authURL(environment: ["HOME": "/fixture", "OPENCODE_DB": ":memory:"])
        }
    }

    @Test func savesV2CredentialRatherThanStaleLegacyFile() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.auth("stale"))
        let before = try Data(contentsOf: fixture.authURL)
        let live = try fixture.auth("live")
        let client = V2TestClient(live)
        let service = service(fixture, client: client)
        let identity = try await service.saveCurrent(for: fixture.profile("live"))
        #expect(try identity == live.identity())
        #expect(try fixture.saved(identity) == live)
        #expect(try Data(contentsOf: fixture.authURL) == before)
    }

    @Test func legacySnapshotsImportOnceThenUseNativeActivation() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let target = try fixture.auth("target")
        let targetProfile = try await fixture.prepareTarget(target)
        let before = try Data(contentsOf: fixture.authURL)
        let original = try fixture.auth("original")
        let client = V2TestClient(original)
        let service = service(fixture, client: client)
        var originalProfile = fixture.profile("original")
        originalProfile.openCodeOpenAIAccount = try await service.saveCurrent(for: originalProfile)
        try await service.switchTo(profile: targetProfile)
        #expect(try await client.read(id: nil).auth == target)
        try await service.switchTo(profile: originalProfile)
        #expect(try await client.read(id: nil).auth == original)
        try await service.switchTo(profile: targetProfile)
        #expect(await client.imports == 1)
        #expect(await client.activations == 2)
        #expect(try Data(contentsOf: fixture.authURL) == before)
    }

    @Test func failedPostSwitchVerificationRestoresNativeConnection() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let original = try fixture.auth("original")
        let client = V2TestClient(original)
        let verifier = V2TestVerifier(failAt: 2)
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await service(fixture, client: client, verifier: verifier).switchTo(profile: profile)
        }
        #expect(error?.recovery == .restored)
        #expect(try await client.read(id: nil).auth == original)
    }

    @Test func lostImportResponseIsReconciledAndRolledBack() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let original = try fixture.auth("original")
        let client = V2TestClient(original, loseImportResponse: true)
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await service(fixture, client: client).switchTo(profile: profile)
        }
        #expect(error?.recovery == .restored)
        #expect(try await client.read(id: nil).auth == original)
    }

    @Test func concurrentSwitchIsNeverRolledBack() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let external = try fixture.auth("external")
        let client = try V2TestClient(fixture.auth("original"))
        let verifier = V2TestVerifier(onVerify: { count in
            if count == 2 { await client.changeExternally(external) }
        })
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await service(fixture, client: client, verifier: verifier).switchTo(profile: profile)
        }
        #expect(error?.recovery == .changedExternally)
        #expect(try await client.read(id: nil).auth == external)
        #expect(await client.activations == 0)
    }

    @Test func cancellationAfterInstallRestoresOriginalConnection() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let original = try fixture.auth("original")
        let client = V2TestClient(original)
        let verifier = V2TestVerifier(onVerify: { count in
            if count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let service = service(fixture, client: client, verifier: verifier)
        let error = await Task {
            await #expect(throws: OpenCodeOpenAISwitchError.self) { try await service.switchTo(profile: profile) }
        }.value
        #expect(error?.recovery == .restored)
        #expect(try await client.read(id: nil).auth == original)
    }

    @Test func refreshedCurrentAccountNeverRestoresConsumedTokens() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let expired = try fixture.auth("target", expires: 0)
        let profile = try await fixture.prepareTarget(expired)
        let refreshed = try fixture.auth("target", refresh: "rotated")
        let client = V2TestClient(expired)
        let verifier = V2TestVerifier(failAt: 1, refreshed: refreshed)
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await service(fixture, client: client, verifier: verifier).switchTo(profile: profile)
        }
        #expect(error?.recovery == .currentSignInRefreshed)
        #expect(try await client.read(id: nil).auth == refreshed)
        #expect(try fixture.saved(refreshed.identity()) == refreshed)
    }

    @Test func refreshedInactiveCredentialSurvivesFailureAndRetry() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let expired = try fixture.auth("target", expires: 0)
        var profile = fixture.profile("target")
        let original = try fixture.auth("original")
        let client = V2TestClient(expired)
        let refreshed = try fixture.auth("target", refresh: "rotated")
        let verifier = V2TestVerifier(failAt: 1, refreshed: refreshed)
        let service = service(fixture, client: client, verifier: verifier)
        profile.openCodeOpenAIAccount = try await service.saveCurrent(for: profile)
        await client.changeExternally(original)
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) { try await service.switchTo(profile: profile) }
        #expect(error?.recovery == .restored)
        #expect(try await client.read(id: nil).auth == original)
        try await service.switchTo(profile: profile)
        #expect(try await client.read(id: nil).auth == refreshed)
        #expect(await client.imports == 1)
    }

    private func service(_ fixture: OpenCodeAuthFixture, client: V2TestClient,
                         verifier: V2TestVerifier = V2TestVerifier()) -> OpenCodeOpenAIAuthService {
        OpenCodeOpenAIAuthService(homeDirectory: fixture.home,
                                 resolveRuntime: { OpenCodeLocalRuntime(authURL: fixture.authURL, v2: client) },
                                 verifier: verifier, now: { OpenCodeAuthFixture.now })
    }
}

private actor V2TestClient: OpenCodeV2Serving {
    private var current: OpenCodeV2Credential
    private var credentials: [String: OpenCodeV2Credential]
    private let loseImportResponse: Bool
    private(set) var imports = 0
    private(set) var activations = 0

    init(_ auth: OpenCodeOpenAIAuth, loseImportResponse: Bool = false) {
        current = OpenCodeV2Credential(id: "cred_original", auth: auth)
        credentials = [current.id: current]
        self.loseImportResponse = loseImportResponse
    }

    func read(id: String?) throws -> OpenCodeV2Credential {
        guard let value = id == nil ? current : credentials[id!] else { throw OpenCodeOpenAIAuthError.providerMissing }
        return value
    }

    func install(_ auth: OpenCodeOpenAIAuth, expected: OpenCodeV2Credential) throws -> OpenCodeV2Credential {
        guard current == expected else { throw OpenCodeOpenAIAuthError.changedWhileReading }
        imports += 1
        current = OpenCodeV2Credential(id: "cred_import_\(imports)", auth: auth)
        credentials[current.id] = current
        if loseImportResponse { throw URLError(.cancelled) }
        return current
    }

    func activate(_ credential: OpenCodeV2Credential, expected: OpenCodeV2Credential) throws -> OpenCodeV2Credential {
        guard current == expected else { throw OpenCodeOpenAIAuthError.changedWhileReading }
        activations += 1
        current = try read(id: credential.id)
        return current
    }

    func changeExternally(_ auth: OpenCodeOpenAIAuth) {
        current = OpenCodeV2Credential(id: "cred_external", auth: auth)
        credentials[current.id] = current
    }
}

private actor V2TestVerifier: OpenCodeOpenAICredentialVerifying {
    let failAt: Int?
    let refreshed: OpenCodeOpenAIAuth?
    let onVerify: @Sendable (Int) async -> Void
    var count = 0

    init(failAt: Int? = nil, refreshed: OpenCodeOpenAIAuth? = nil,
         onVerify: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.failAt = failAt
        self.refreshed = refreshed
        self.onVerify = onVerify
    }

    func verify(_ auth: OpenCodeOpenAIAuth) async throws {
        count += 1
        await onVerify(count)
        if count == failAt { throw OpenCodeOpenAIVerificationError.unauthorized }
    }

    func refresh(_ auth: OpenCodeOpenAIAuth) throws -> OpenCodeOpenAIAuth {
        try #require(refreshed, "Unexpected token refresh")
    }
}
