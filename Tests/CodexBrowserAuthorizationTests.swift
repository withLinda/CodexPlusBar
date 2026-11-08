import Darwin
import Foundation
import Testing
@testable import CodexPlusBar

@Suite(.serialized)
struct CodexBrowserAuthorizationTests {
    @Test func consecutiveLoginsOpenBrowserAfterCompletedCallback() async throws {
        let fixture = try LoginHelperFixture(mode: "callback-success"); defer { fixture.remove() }
        let profile = CodexSignInFixture.profile(), output = RepairURLRecorder()
        let helper = CodexBrowserAuthorization(executable: fixture.script, timeout: .seconds(10), homeDirectory: fixture.directory)
        for _ in 0..<2 {
            let signIn = try await helper.authorize(profile: profile) { url in
                await output.append(url)
                // Exercise the real TCP callback lifecycle without OAuth or Chrome.
                // The fixture actively closes its connection, leaving TIME_WAIT.
                let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:1455/test-callback")!)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }
            #expect(signIn == fixture.signIn)
            try await helper.acknowledge(signIn, profile: profile)
        }
        #expect(await output.urls.count == 2)
    }

    @Test(arguments: [UInt16(1455), UInt16(1457)], ["127.0.0.1", "0.0.0.0"])
    func activeCallbackListenerStillBlocksLoginWithoutContact(port: UInt16, host: String) async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { close(listener) }
        var reuse: Int32 = 1
        #expect(setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        address.sin_port = port.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        let fixture = try LoginHelperFixture(mode: "success"); defer { fixture.remove() }
        await #expect(throws: AppSignInRepairError.loginBusy) {
            _ = try await CodexBrowserAuthorization(executable: fixture.script, timeout: .seconds(5), homeDirectory: fixture.directory)
                .authorize(profile: CodexSignInFixture.profile()) { _ in Issue.record("Opened browser while another login owned the callback") }
        }
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        let contacted = accept(listener, nil, nil)
        let acceptError = errno
        if contacted >= 0 { close(contacted) }
        #expect(contacted == -1)
        #expect(acceptError == EWOULDBLOCK || acceptError == EAGAIN)
    }

    @Test func completedGrantSurvivesUntilDurableHandoff() async throws {
        let fixture = try LoginHelperFixture(mode: "success"); defer { fixture.remove() }
        let profile = CodexSignInFixture.profile()
        let helper = CodexBrowserAuthorization(executable: fixture.script, timeout: .seconds(5), homeDirectory: fixture.directory)
        let first = try await helper.authorize(profile: profile) { _ in }
        try FileManager.default.removeItem(at: fixture.script)
        let restarted = CodexBrowserAuthorization(executable: fixture.script, homeDirectory: fixture.directory)
        let recovered = try await restarted.authorize(profile: profile) { _ in Issue.record("Recovered login reopened Chrome") }
        #expect(recovered == first)
        try await restarted.acknowledge(first, profile: profile)
        await #expect(throws: AppSignInRepairError.helperUnavailable) {
            _ = try await restarted.authorize(profile: profile) { _ in }
        }
    }
    @Test(arguments: ["success", "early"])
    func helperUsesIsolatedHomeAndMatchesCompletionID(mode: String) async throws {
        let fixture = try LoginHelperFixture(mode: mode); defer { fixture.remove() }
        let output = RepairURLRecorder()
        let result = try await CodexBrowserAuthorization(executable: fixture.script, timeout: .seconds(5), homeDirectory: fixture.directory)
            .authorize(profile: CodexSignInFixture.profile()) { await output.append($0) }
        #expect(result == fixture.signIn)
        #expect(await output.urls.count == 1)
    }

    @Test func deniedEarlyCompletionDoesNotWaitForTimeout() async throws {
        let fixture = try LoginHelperFixture(mode: "early-denied"); defer { fixture.remove() }
        await #expect(throws: AppSignInRepairError.denied) {
            _ = try await CodexBrowserAuthorization(executable: fixture.script, timeout: .seconds(5), homeDirectory: fixture.directory)
                .authorize(profile: CodexSignInFixture.profile()) { _ in }
        }
    }

    @Test func cancelledBrowserOpeningStaysCancellation() async throws {
        let fixture = try LoginHelperFixture(mode: "unrelated"); defer { fixture.remove() }
        await #expect(throws: CancellationError.self) {
            _ = try await CodexBrowserAuthorization(executable: fixture.script, timeout: .seconds(5), homeDirectory: fixture.directory)
                .authorize(profile: CodexSignInFixture.profile()) { _ in throw CancellationError() }
        }
    }

    @Test func cancellationAfterHelperSavedGrantReturnsItForDurableRecovery() async throws {
        let fixture = try LoginHelperFixture(mode: "saved-before-event"); defer { fixture.remove() }
        let barrier = SyncBarrier()
        let task = Task {
            do {
                return try await CodexBrowserAuthorization(executable: fixture.script, timeout: .seconds(5), homeDirectory: fixture.directory)
                    .authorize(profile: CodexSignInFixture.profile()) { _ in await barrier.wait() }
            } catch {
                await barrier.wait()
                throw error
            }
        }
        await barrier.started(); task.cancel(); await barrier.release()
        #expect(try await task.value == fixture.signIn)
    }

    @Test func helperTimeoutAndUnrelatedCompletionCannotReportSuccess() async throws {
        let fixture = try LoginHelperFixture(mode: "unrelated"); defer { fixture.remove() }
        await #expect(throws: AppSignInRepairError.timedOut) {
            _ = try await CodexBrowserAuthorization(executable: fixture.script, timeout: .milliseconds(300), homeDirectory: fixture.directory)
                .authorize(profile: CodexSignInFixture.profile()) { _ in }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCHAMBER_V2_TEST_URL"] != nil))
    func installedOfficialHelperStartsAndCancelsWithoutSigningIn() async throws {
        let output = RepairURLRecorder()
        let home = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: home) }
        for _ in 0..<2 {
            await #expect(throws: CancellationError.self) {
                _ = try await CodexBrowserAuthorization(timeout: .seconds(20), homeDirectory: home).authorize(profile: CodexSignInFixture.profile()) { url in
                    try CodexBrowserAuthorization.validateURL(url)
                    await output.append(url)
                    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                    let redirect = try #require(components.queryItems?.first { $0.name == "redirect_uri" }?.value)
                    var probe = try #require(URLComponents(string: redirect))
                    probe.path = "/codexplusbar-callback-probe"
                    var request = URLRequest(url: try #require(probe.url))
                    request.setValue("close", forHTTPHeaderField: "Connection")
                    request.timeoutInterval = 5
                    let (_, response) = try await URLSession.shared.data(for: request)
                    #expect((response as? HTTPURLResponse)?.statusCode == 404)
                    throw CancellationError()
                }
            }
        }
        #expect(await output.urls.count == 2)
    }
}

actor RepairURLRecorder {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

private struct LoginHelperFixture {
    let directory: URL
    let script: URL
    let signIn: CodexSignIn
    init(mode: String) throws {
        directory = try CodexSignInFixture.directory()
        script = directory.appendingPathComponent("login-helper")
        signIn = try CodexSignIn(data: CodexSignInFixture.data())
        let encoded = signIn.data.base64EncodedString()
        let source = """
        #!/usr/bin/python3
        import sys, os, json, base64, socket
        from pathlib import Path
        from urllib.parse import urlencode
        assert Path(os.environ['HOME']).resolve() == Path(os.environ['CODEX_HOME']).resolve() == Path.cwd()
        assert 'OPENAI_API_KEY' not in os.environ and 'CODEX_AUTH_JSON' not in os.environ
        def send(message): print(json.dumps(message), flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            if request['method']=='initialize': send({'id':request['id'],'result':{}})
            elif request['method']=='account/login/start':
                url='https://auth.openai.com/oauth/authorize?'+urlencode(dict(client_id='app_EMoamEEZ73f0CkXaXp7hrann',response_type='code',redirect_uri='http://127.0.0.1:1455/auth/callback',code_challenge_method='S256',code_challenge='fixture',state='fixture'))
                if '\(mode)'=='callback-success':
                    with socket.socket() as server:
                        server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
                        server.bind(('127.0.0.1',1455)); server.listen(1); server.settimeout(5)
                        send({'id':request['id'],'result':{'type':'chatgpt','loginId':'expected','authUrl':url}})
                        connection,_=server.accept()
                        with connection:
                            connection.settimeout(5)
                            assert b'/test-callback' in connection.recv(8192)
                            connection.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n')
                            connection.shutdown(socket.SHUT_WR)
                            while connection.recv(8192): pass
                    Path('auth.json').write_bytes(base64.b64decode('\(encoded)'))
                    send({'method':'account/login/completed','params':{'loginId':'expected','success':True}})
                    continue
                if '\(mode)' not in ('unrelated','early-denied'): Path('auth.json').write_bytes(base64.b64decode('\(encoded)'))
                if '\(mode)' in ('early','early-denied'): send({'method':'account/login/completed','params':{'loginId':'expected','success':'\(mode)'=='early'}})
                send({'id':request['id'],'result':{'type':'chatgpt','loginId':'expected','authUrl':url}})
                send({'method':'account/login/completed','params':{'loginId':'unrelated','success':True}})
                if '\(mode)'=='success': send({'method':'account/login/completed','params':{'loginId':'expected','success':True}})
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
