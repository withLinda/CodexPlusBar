import Foundation
import Testing
@testable import CodexPlusBar

struct OpenCodeOpenAIVerificationTests {
    @Test func serviceSerializesActionsWhileVerificationIsSuspended() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let gate = OpenAIVerificationGate()
        let runtime = OpenCodeLocalRuntime(authURL: fixture.authURL)
        let service = OpenCodeOpenAIAuthService(homeDirectory: fixture.home, resolveRuntime: { runtime },
                                               verifier: gate, now: { OpenCodeAuthFixture.now })
        let task = Task { try await service.switchTo(profile: profile) }
        await gate.waitUntilStarted()
        await #expect(throws: OpenCodeOpenAIAuthError.busy) { try await service.switchTo(profile: profile) }
        await #expect(throws: OpenCodeOpenAIAuthError.busy) { try await service.saveCurrent(for: profile) }
        await gate.finish()
        try await task.value
        #expect(try fixture.current().accountId == "account-target")
    }

    @Test func switchVerifiesBeforeAndAfterWriteWithExactTargetHeaders() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let target = try fixture.auth("target")
        let profile = try await fixture.prepareTarget(target)
        let outgoing = try fixture.current()
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.usage(), .usage()]) { index, request in
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(target.access)")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == target.accountId)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.timeoutInterval == 15)
            let currentData = try Data(contentsOf: fixture.authURL)
            let current = try fixture.current()
            if index == 0 { #expect(currentData == before) }
            else { #expect(current == target) }
        }
        try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        #expect(await script.count == 2)
        #expect(try fixture.current() == target)
        #expect(try fixture.othersUnchanged())
        #expect(try fixture.saved(outgoing.identity()) == outgoing)
    }

    @Test(arguments: [false, true])
    func expiredStoredOrJWTTokenIsRefreshedAndBothRotatedTokensAreSaved(jwtExpired: Bool) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let target = try fixture.auth("target", refresh: "refresh&+ =/?", expires: jwtExpired ? 2_000_000_000_000 : 0,
                                      jwtExpiry: jwtExpired ? OpenCodeAuthFixture.now.timeIntervalSince1970 - 1 : nil)
        let rotated = try fixture.auth("target", refresh: "rotated-pair", jwtExpiry: 2_000_000_000)
        let profile = try await fixture.prepareTarget(target)
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([try .tokens(rotated), .usage(), .usage()]) { index, request in
            if index == 0 {
                #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
                #expect(body == "grant_type=refresh_token&refresh_token=refresh%26%2B%20%3D%2F%3F&client_id=app_EMoamEEZ73f0CkXaXp7hrann")
            } else {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(rotated.access)")
                #expect(try fixture.saved(rotated.identity()).refresh == rotated.refresh)
            }
            if index < 2 { #expect(try Data(contentsOf: fixture.authURL) == before) }
        }
        try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        let current = try fixture.current()
        #expect(current.access == rotated.access)
        #expect(current.refresh == rotated.refresh)
        #expect(current.expires == 1_700_003_600_000)
        #expect(try fixture.saved(current.identity()) == current)
        #expect(await script.count == 3)
        #expect(try fixture.othersUnchanged())
    }

    @Test func rejectedUnexpiredTokenRefreshesOnceAndRetriesWithNewAccess() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let rotated = try fixture.auth("target", refresh: "rotated", jwtExpiry: 2_000_000_000)
        let script = OpenAIRequestScript([.usage(401), try .tokens(rotated), .usage(), .usage()]) { index, request in
            if index >= 2 { #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(rotated.access)") }
        }
        try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        #expect(await script.count == 4)
        #expect(try fixture.current().refresh == rotated.refresh)
    }

    @Test(arguments: [403, 429, 500, 302])
    func preflightHTTPFailureNeverChangesLiveSignInOrRefreshes(status: Int) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.usage(status)])
        let service = fixture.switchingService(request: { try await script.send($0) })
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) { try await service.switchTo(profile: profile) }
        #expect(error?.recovery == .unchanged)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(await script.count == 1)
    }

    @Test(arguments: [URLError.notConnectedToInternet, .timedOut])
    func preflightNetworkFailurePreservesLiveSignIn(code: URLError.Code) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.failure(code)])
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .unchanged)
        #expect(error?.reason == OpenCodeOpenAIVerificationError.unavailable.localizedDescription)
        #expect(try Data(contentsOf: fixture.authURL) == before)
    }

    @Test func revokedRefreshTokenNeverReplacesActiveAccount() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.usage(401), .body(400, #"{"error":"invalid_grant","error_description":"private-sentinel"}"#)])
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .unchanged)
        #expect(error?.reason == OpenCodeOpenAIVerificationError.reauthenticationRequired.localizedDescription)
        #expect(error?.localizedDescription.contains("private-sentinel") == false)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(await script.count == 2)
    }

    @Test func secondUnauthorizedDoesNotLoopAndRetainsRefreshedSnapshotForRetry() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let before = try Data(contentsOf: fixture.authURL)
        let rotated = try fixture.auth("target", refresh: "new-refresh", jwtExpiry: 2_000_000_000)
        let script = OpenAIRequestScript([.usage(401), try .tokens(rotated), .usage(401), .usage(), .usage()])
        let service = fixture.switchingService(request: { try await script.send($0) })
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) { try await service.switchTo(profile: profile) }
        #expect(error?.recovery == .unchanged)
        #expect(await script.count == 3)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(try fixture.saved(rotated.identity()).refresh == rotated.refresh)
        try await service.switchTo(profile: profile)
        #expect(try fixture.current().refresh == rotated.refresh)
        #expect(await script.count == 5)
    }

    @Test(arguments: [401, 403, 500])
    func postWriteHTTPFailureRestoresExactOriginalWithoutRefreshing(status: Int) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.usage(), .usage(status)])
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .restored)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(await script.count == 2)
        #expect(try fixture.othersUnchanged())
    }

    @Test func postWriteTimeoutRollsBackAndClearsBusyStateForRetry() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.usage(), .failure(.timedOut), .usage(), .usage()])
        let service = fixture.switchingService(request: { try await script.send($0) })
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) { try await service.switchTo(profile: profile) }
        #expect(error?.recovery == .restored)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        try await service.switchTo(profile: profile)
        #expect(try fixture.current().accountId == "account-target")
    }

    @Test(arguments: [0, 1])
    func competingWriteBeforeOrAfterInstallIsNeverOverwritten(stage: Int) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let newer = try fixture.auth("other", refresh: "newer-sign-in")
        let script = OpenAIRequestScript([.usage(), .usage()]) { index, _ in
            if index == stage { try fixture.write(newer) }
        }
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .changedExternally)
        #expect(try fixture.current() == newer)
    }

    @Test func unreadableFileDuringRollbackDoesNotClaimRestoration() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let script = OpenAIRequestScript([.usage(), .usage(401)]) { index, _ in
            if index == 1 { try FileManager.default.removeItem(at: fixture.authURL) }
        }
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .rollbackFailed)
        #expect(FileManager.default.fileExists(atPath: fixture.authURL.path) == false)
    }

    @Test func sameAccountUsesLatestLiveTokensAndStillRequiresVerification() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target", refresh: "stale-saved-refresh"))
        let latest = try fixture.auth("target", refresh: "latest-live-refresh", jwtExpiry: 2_000_000_000)
        try fixture.write(latest)
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.usage(403)]) { _, request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(latest.access)")
        }
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .unchanged)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(try fixture.saved(latest.identity()) == latest)
        #expect(await script.count == 1)
    }

    @Test(arguments: [200, 401, 500])
    func sameAccountRefreshNeverRollsBackConsumedToken(status: Int) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let expired = try fixture.auth("target", expires: 0)
        let profile = try await fixture.prepareTarget(expired)
        try fixture.write(expired)
        let rotated = try fixture.auth("target", refresh: "new-current-refresh", jwtExpiry: 2_000_000_000)
        let script = OpenAIRequestScript([try .tokens(rotated), .usage(status)])
        let service = fixture.switchingService(request: { try await script.send($0) })
        if status == 200 {
            try await service.switchTo(profile: profile)
        } else {
            let error = await #expect(throws: OpenCodeOpenAISwitchError.self) { try await service.switchTo(profile: profile) }
            #expect(error?.recovery == .currentSignInRefreshed)
        }
        #expect(try fixture.current().refresh == rotated.refresh)
        #expect(try fixture.saved(rotated.identity()).refresh == rotated.refresh)
        #expect(await script.count == 2)
        #expect(try fixture.othersUnchanged())
    }

    @Test(arguments: [0, 1])
    func cancellationAtVerificationBoundariesCannotReportSuccess(stage: Int) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target"))
        let before = try Data(contentsOf: fixture.authURL)
        let script = OpenAIRequestScript([.usage(), .usage()]) { index, _ in
            if index == stage { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let service = fixture.switchingService(request: { try await script.send($0) })
        let task = Task { try await service.switchTo(profile: profile) }
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) { try await task.value }
        #expect(error?.recovery == (stage == 0 ? .unchanged : .restored))
        #expect(try Data(contentsOf: fixture.authURL) == before)
    }

    @Test func cancellationAfterRefreshRetainsRotatedPair() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let profile = try await fixture.prepareTarget(fixture.auth("target", expires: 0))
        let before = try Data(contentsOf: fixture.authURL)
        let rotated = try fixture.auth("target", refresh: "received-before-cancel")
        let script = OpenAIRequestScript([try .tokens(rotated)]) { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        let service = fixture.switchingService(request: { try await script.send($0) })
        let task = Task { try await service.switchTo(profile: profile) }
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) { try await task.value }
        #expect(error?.recovery == .unchanged)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(try fixture.saved(rotated.identity()).refresh == rotated.refresh)
    }

    @Test(arguments: ["<html>Sign in</html>", "{}", #"{"ok":true}"#, #"{"rate_limit":null}"#])
    func unrelatedSuccessfulResponsesAreNotVerification(body: String) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let script = OpenAIRequestScript([.body(200, body)])
        let verifier = OpenCodeOpenAICredentialVerifier(request: { try await script.send($0) })
        await #expect(throws: OpenCodeOpenAIVerificationError.invalidResponse) { try await verifier.verify(fixture.auth("target")) }
    }

    @Test(arguments: [false, true])
    func refreshCannotInstallDifferentAccountOrUser(sameWorkspace: Bool) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let target = try fixture.auth("target", expires: 0)
        let profile = try await fixture.prepareTarget(target)
        let before = try Data(contentsOf: fixture.authURL)
        let wrong = try fixture.auth(sameWorkspace ? "target" : "wrong", userID: "other-user")
        let script = OpenAIRequestScript([try .tokens(wrong)])
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .unchanged)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(try fixture.saved(target.identity()) == target)
    }

    @Test(arguments: [0, -1])
    func invalidRefreshLifetimeIsRejected(seconds: Int) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let script = OpenAIRequestScript([try .tokens(fixture.auth("target"), lifetime: seconds)])
        let verifier = OpenCodeOpenAICredentialVerifier(request: { try await script.send($0) })
        await #expect(throws: OpenCodeOpenAIVerificationError.invalidResponse) { try await verifier.refresh(fixture.auth("target")) }
    }

    @Test func omittedRefreshTokenKeepsPreviousRefreshToken() async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let target = try fixture.auth("target", refresh: "keep-when-not-rotated")
        let body = try JSONSerialization.data(withJSONObject: ["access_token": target.access])
        let script = OpenAIRequestScript([.body(200, String(decoding: body, as: UTF8.self))])
        let verifier = OpenCodeOpenAICredentialVerifier(request: { try await script.send($0) }, now: { OpenCodeAuthFixture.now })
        let refreshed = try await verifier.refresh(target)
        #expect(refreshed.refresh == target.refresh)
        #expect(refreshed.expires == 1_700_003_600_000)
    }

    @Test(arguments: ["empty-access", "empty-refresh", "malformed-jwt", "missing-access", "overflow-expiry"])
    func malformedRefreshedCredentialsCannotOverwriteSavedOrLiveSignIn(fault: String) async throws {
        let fixture = try OpenCodeAuthFixture()
        defer { fixture.remove() }
        let target = try fixture.auth("target", expires: 0)
        let profile = try await fixture.prepareTarget(target)
        let before = try Data(contentsOf: fixture.authURL)
        var payload: [String: Any] = ["access_token": target.access, "refresh_token": "new-refresh", "expires_in": 3600]
        switch fault {
        case "empty-access": payload["access_token"] = ""
        case "empty-refresh": payload["refresh_token"] = ""
        case "malformed-jwt": payload["access_token"] = "invalid.jwt.credential"
        case "missing-access": payload.removeValue(forKey: "access_token")
        default: payload["expires_in"] = 1e30
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let script = OpenAIRequestScript([.body(200, String(decoding: body, as: UTF8.self))])
        let error = await #expect(throws: OpenCodeOpenAISwitchError.self) {
            try await fixture.switchingService(request: { try await script.send($0) }).switchTo(profile: profile)
        }
        #expect(error?.recovery == .unchanged)
        #expect(try Data(contentsOf: fixture.authURL) == before)
        #expect(try fixture.saved(target.identity()) == target)
    }
}

private actor OpenAIVerificationGate: OpenCodeOpenAICredentialVerifying {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func verify(_ auth: OpenCodeOpenAIAuth) async throws {
        if hasStarted { return }
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func refresh(_ auth: OpenCodeOpenAIAuth) async throws -> OpenCodeOpenAIAuth {
        Issue.record("Unexpected refresh")
        throw OpenCodeOpenAIAuthError.invalidCredential
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor OpenAIRequestScript {
    enum Reply: Sendable {
        case body(Int, String)
        case failure(URLError.Code)

        static func usage(_ status: Int = 200) -> Self { .body(status, #"{"rate_limit":{"primary_window":{"used_percent":42}}}"#) }
        static func tokens(_ auth: OpenCodeOpenAIAuth, lifetime: Int = 3600) throws -> Self {
            let body = try JSONSerialization.data(withJSONObject: [
                "access_token": auth.access, "refresh_token": auth.refresh, "expires_in": lifetime,
            ])
            return .body(200, String(decoding: body, as: UTF8.self))
        }
    }

    private let replies: [Reply]
    private let willRespond: @Sendable (Int, URLRequest) throws -> Void
    private(set) var count = 0

    init(_ replies: [Reply], willRespond: @escaping @Sendable (Int, URLRequest) throws -> Void = { _, _ in }) {
        self.replies = replies
        self.willRespond = willRespond
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let index = count
        count += 1
        try #require(replies.indices.contains(index), "Unexpected extra network request")
        try willRespond(index, request)
        switch replies[index] {
        case let .body(status, body):
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        case let .failure(code): throw URLError(code)
        }
    }
}
