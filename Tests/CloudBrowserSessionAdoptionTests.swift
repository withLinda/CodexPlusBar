import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor struct CloudBrowserSessionAdoptionTests {
    @Test func defaultStorageLayoutSupportsAbsentReadsAndPrivateRecovery() throws {
        let fixture = try CloudBrowserSeedTestStorage()
        let store = fixture.store, profile = CodexSignInFixture.profile()
        #expect(try store.load(for: profile) == nil)
        try store.remove(for: profile)
        #expect(FileManager.default.fileExists(atPath: store.directory.path) == false)

        let payload = try browserPayload([browserCookie("__Secure-next-auth.session-token")])
        try store.save(payload, for: profile)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let restarted = CloudBrowserSeedStore(directory: store.directory)
        #expect(try restarted.load(for: profile)?.payload == payload)
        try restarted.remove(for: profile)
        #expect(try restarted.load(for: profile) == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test func browserRecoveryStillRejectsAccountTreeStorage() throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudBrowserSeedStore(directory: root.appendingPathComponent("CodexPlusBar/CloudBrowserSeeds"))
        #expect(throws: CloudJournalError.unsafePath) { try store.load(for: CodexSignInFixture.profile()) }
        #expect(FileManager.default.fileExists(atPath: store.directory.path) == false)
    }

    @Test func browserRecoveryRejectsRedirectedDirectory() throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("seeds")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = CloudBrowserSeedStore(directory: link), profile = CodexSignInFixture.profile()
        #expect(throws: (any Error).self) { try store.save(browserPayload([browserCookie("__Secure-next-auth.session-token")]), for: profile) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func browserImportUsesSessionEndpointIdentityAndResponseCookies(wrongUser: Bool) async throws {
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry()
        let adoption = CloudBrowserSessionAdoption(registry: registry, verify: { runtime in
            let transport = BrowserAdoptionTransport(store: runtime.sessionStore, wrongUser: wrongUser)
            return try await AuthSessionService(transport: transport, sessionStore: runtime.sessionStore).fetchCurrentSession()
        })
        let payload = try browserPayload([browserCookie("__Secure-next-auth.session-token", value: "incoming")])
        if wrongUser {
            await #expect(throws: CloudSessionError.identityMismatch) { try await adoption.prepare(payload, for: profile) }
        } else {
            let fresh = try await adoption.prepare(payload, for: profile)
            let prepared = try await adoption.preparedPayload(profileID: profile.id)
            guard case .browser(let cookies, let identity, _) = prepared else { Issue.record("Missing browser payload"); return }
            #expect(identity.userID == "user")
            #expect(cookies.contains { $0.value == "response" })
            try adoption.commit(profileID: profile.id)
            try? await registry.removeProfileData(for: fresh)
        }
        try? await registry.removeProfileData(for: profile)
    }

    @Test func browserRevocationAfterLocalRejectionStopsRemoteVerification() async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry(), admission = AdoptionAdmissionFlag()
        let old = registry.runtime(for: profile)
        await old.sessionStore.storeCookies([try #require(browserCookie("__Secure-next-auth.session-token", value: "local").cookie)])
        var calls = 0
        let adoption = CloudBrowserSessionAdoption(registry: registry, verify: { runtime in
            calls += 1
            if runtime === old { admission.allowed = false; throw ChatGPTAPIError.unauthorized }
            return try browserContext()
        })
        let service = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: BrowserSeedChromeSpy(),
            browserAdoption: adoption, browserSeeds: .init(directory: root.appendingPathComponent("seeds")))
        await #expect(throws: CloudSessionError.unavailable) {
            try await service.adoptBrowserSession(browserPayload([browserCookie("__Secure-next-auth.session-token")]), for: profile,
                authorization: adoptionAuthorization(profile) { try admission.check() })
        }
        #expect(calls == 1)
        #expect(await old.sessionStore.cookieValue(named: "__Secure-next-auth.session-token") == "local")
        try? await registry.removeProfileData(for: profile)
    }

    @Test func catalogWriteThenThrowKeepsRecoveryForCommittedStore() async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry()
        let seeds = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds"))
        let catalog = ProfileCatalogStore(fileURL: root.appendingPathComponent("profiles.json"))
        try catalog.saveProfiles([profile])
        let service = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: BrowserSeedChromeSpy(),
            browserAdoption: .init(registry: registry, verify: { _ in try browserContext() }), browserSeeds: seeds)
        var auth = adoptionAuthorization(profile)
        auth.browserCompleted = { fresh, _ in try catalog.saveProfiles([fresh]); throw AppSignInRepairError.storageFailed }
        auth.browserCommitStatus = { fresh in try catalog.loadProfiles().contains { $0.id == fresh.id && $0.webDataStoreID == fresh.webDataStoreID } }
        await #expect(throws: AppSignInRepairError.storageFailed) {
            try await service.adoptBrowserSession(browserPayload([browserCookie("__Secure-next-auth.session-token")]), for: profile, authorization: auth)
        }
        let saved = try #require(try catalog.loadProfiles().first)
        #expect(try seeds.load(for: saved) != nil)
        let restarted = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: BrowserSeedChromeSpy(), browserSeeds: seeds)
        try await restarted.openChromeAccountPage(for: saved)
        #expect(await registry.runtime(for: saved).sessionStore.cookieValue(named: "__Secure-next-auth.session-token") == "synthetic")
        try? await registry.removeProfileData(for: saved)
    }

    @Test func newerLocalCookiesInvalidateQueuedSeed() async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry()
        let seeds = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds")), chrome = BrowserSeedChromeSpy()
        try seeds.save(browserPayload([browserCookie("__Secure-next-auth.session-token", value: "old")]), for: profile)
        await registry.runtime(for: profile).sessionStore.storeCookies([try #require(browserCookie("__Secure-next-auth.session-token", value: "new").cookie)])
        let service = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: chrome, browserSeeds: seeds)
        try await service.openChromeAccountPage(for: profile)
        #expect(chrome.seeds == 0)
        #expect(try seeds.load(for: profile) == nil)
        #expect(await registry.runtime(for: profile).sessionStore.cookieValue(named: "__Secure-next-auth.session-token") == "new")
        try? await registry.removeProfileData(for: profile)
    }

    @Test func coordinatorCommitsNewBrowserStoreThroughExplicitInboxRequest() async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let keys = CloudTransportKeys(try CloudCryptoFixture.key()), registry = ProfileRuntimeRegistry()
        let adoption = CloudBrowserSessionAdoption(registry: registry, verify: { _ in try browserContext() })
        let seeds = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds"))
        let service = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: BrowserSeedChromeSpy(), browserAdoption: adoption, browserSeeds: seeds)
        let f = try SessionFixture(inboxKeys: keys, dataService: service); defer { f.clean() }
        let old = registry.runtime(for: f.profile)
        await f.coordinator.start(); await f.coordinator.setEnabled(true)
        let payload = try browserPayload([browserCookie("__Secure-next-auth.session-token")])
        let request = try await receiveAdoption(payload, in: f, keys: keys)
        try await f.coordinator.adoptSession(request)
        let committed = try #require(try f.store.loadProfiles().first)
        #expect(committed.webDataStoreID != f.profile.webDataStoreID)
        #expect(await registry.runtime(for: committed).sessionStore.cookieValue(named: "__Secure-next-auth.session-token") == "synthetic")
        #expect(try seeds.load(for: committed) != nil)
        #expect(await old.sessionStore.portableChatGPTCookies().isEmpty)
        await f.coordinator.stop()
        await old.sessionStore.clear(); try? await registry.removeProfileData(for: f.profile)
        try? await registry.removeProfileData(for: committed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLOUD_BROWSER_RUNTIME_PROBE"] == "1"))
    func isolatedChromeSeedPersistsAndReplacesChunkedFamily() async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile()
        let launcher = ChromeLauncher(profileStore: .init(rootDirectory: root.appendingPathComponent("chrome")))
        let manager = DefaultChromeSessionManager(launcher: launcher)
        let first = [browserCookie("__Secure-next-auth.session-token.0", value: "chunk0", expires: .now.addingTimeInterval(3_600)),
                     browserCookie("__Secure-next-auth.session-token.1", value: "chunk1", expires: .now.addingTimeInterval(3_600))]
        try await manager.seedCookies(first, for: profile)
        let second = [browserCookie("__Secure-next-auth.session-token", value: "whole", expires: .now.addingTimeInterval(3_600)),
                      browserCookie("session-only", value: "retained")]
        try await manager.seedCookies(second, for: profile)
        let session = try await launcher.launch(profile: profile, mode: .headless, initialURL: URL(string: "about:blank")!, requiresDevTools: true)
        let endpoint = try #require(session.endpoint)
        let client = try await ChromeDevToolsClient.connect(versionURL: endpoint.browserURL)
        do {
            let cookies = try await client.getCookies()
            #expect(cookies.contains { $0.name == second[0].name && $0.value == "whole" })
            #expect(cookies.contains { $0.name == "session-only" && $0.value == "retained" && ($0.expires ?? -1) <= 0 })
            #expect(!cookies.contains { $0.name.hasPrefix("__Secure-next-auth.session-token.") })
            try await client.closeBrowser()
        } catch { try? await client.closeBrowser(); throw error }
    }

    @Test(arguments: [false, true])
    func pendingChromeSeedRunsOnceAndRetriesAfterFailure(failFirst: Bool) async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), store = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds"))
        let payload = try browserPayload([browserCookie("__Secure-next-auth.session-token")])
        try store.save(payload, for: profile)
        let chrome = BrowserSeedChromeSpy(); chrome.failSeed = failFirst
        let registry = ProfileRuntimeRegistry()
        let service = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: chrome, browserSeeds: store)
        if failFirst {
            await #expect(throws: CloudSessionError.unavailable) { try await service.openChromeAccountPage(for: profile) }
            #expect(try store.load(for: profile) != nil)
            #expect(chrome.opens == 0)
            chrome.failSeed = false
        }
        try await service.openChromeAccountPage(for: profile)
        try await service.openChromeAccountPage(for: profile)
        #expect(chrome.seeds == (failFirst ? 2 : 1))
        #expect(chrome.opens == 2)
        #expect(try store.load(for: profile)?.payload == payload)
    }

    @Test func savedBrowserRecoveryRestoresSessionCookiesAfterRuntimeRestartButNotAfterClear() async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), store = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds"))
        let registry = ProfileRuntimeRegistry()
        try store.save(browserPayload([browserCookie("__Secure-next-auth.session-token", value: "recover")]), for: profile)
        let service = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: BrowserSeedChromeSpy(), browserSeeds: store)
        try await service.openChromeAccountPage(for: profile)
        #expect(await registry.runtime(for: profile).sessionStore.cookieValue(named: "__Secure-next-auth.session-token") == "recover")
        try await service.clearSession(for: profile)
        try await service.openChromeAccountPage(for: profile)
        #expect(await registry.runtime(for: profile).sessionStore.portableChatGPTCookies().isEmpty)
        #expect(try store.load(for: profile) == nil)
        try? await registry.removeProfileData(for: profile)
    }

    @Test func explicitNewBrowserSignInDiscardsOldPendingSeed() async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), store = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds"))
        try store.save(browserPayload([browserCookie("__Secure-next-auth.session-token")]), for: profile)
        let chrome = BrowserSeedChromeSpy()
        let service = PlusProfileDataService(runtimeProvider: ProfileRuntimeRegistry(), chromeSessionManager: chrome, browserSeeds: store)
        try await service.openChromeSignIn(for: profile)
        try await service.openChromeAccountPage(for: profile)
        #expect(chrome.seeds == 0)
        #expect(try store.load(for: profile) == nil)
    }
    @Test(arguments: [false, true])
    func dataServicePublishesOnlyAfterCatalogAcceptance(catalogFails: Bool) async throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry(), old = registry.runtime(for: profile)
        let payload = try browserPayload([browserCookie("__Secure-next-auth.session-token")])
        let seeds = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds"))
        let adoption = CloudBrowserSessionAdoption(registry: registry, verify: { _ in try browserContext() })
        let service = PlusProfileDataService(runtimeProvider: registry, chromeSessionManager: BrowserSeedChromeSpy(), browserAdoption: adoption, browserSeeds: seeds)
        let result = BrowserAdoptionResult()
        var auth = adoptionAuthorization(profile)
        auth.browserCompleted = { incoming, remote in
            #expect(remote)
            #expect(registry.runtime(for: profile) === old)
            #expect(try seeds.load(for: incoming) != nil)
            result.profile = incoming
            if catalogFails { throw AppSignInRepairError.storageFailed }
        }
        if catalogFails {
            await #expect(throws: AppSignInRepairError.storageFailed) { try await service.adoptBrowserSession(payload, for: profile, authorization: auth) }
            #expect(registry.runtime(for: profile) === old)
            if let staged = result.profile { #expect(try seeds.load(for: staged) == nil) }
        } else {
            try await service.adoptBrowserSession(payload, for: profile, authorization: auth)
            let incoming = try #require(result.profile)
            #expect(await registry.runtime(for: incoming).sessionStore.cookieValue(named: "__Secure-next-auth.session-token") == "synthetic")
            #expect(try await service.captureSavedSession(for: incoming) != nil)
            try? await registry.removeProfileData(for: incoming)
        }
        await old.sessionStore.clear(); try? await registry.removeProfileData(for: profile)
    }

    @Test func pendingChromeSeedSurvivesRestartAndIsScopedToNewStore() throws {
        let root = try CodexSignInFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexSignInFixture.profile(), fresh = profile.reidentified(profile.id, webDataStoreID: UUID())
        let store = CloudBrowserSeedStore(directory: root.appendingPathComponent("seeds"))
        let payload = try browserPayload([browserCookie("__Secure-next-auth.session-token")])
        try store.save(payload, for: fresh)
        let restarted = CloudBrowserSeedStore(directory: store.directory)
        #expect(try restarted.load(for: fresh)?.payload == payload)
        #expect(try restarted.load(for: profile) == nil)
        try restarted.remove(for: profile)
        #expect(try restarted.load(for: fresh) != nil)
        try restarted.remove(for: fresh)
        #expect(try restarted.load(for: fresh) == nil)
    }

    @Test(arguments: [false, true])
    func workingBrowserSessionIsPreferredAndNetworkErrorIsInconclusive(networkError: Bool) async throws {
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry(), old = registry.runtime(for: profile)
        await old.sessionStore.storeCookies([try #require(browserCookie("__Secure-next-auth.session-token", value: "local").cookie)])
        let adoption = CloudBrowserSessionAdoption(registry: registry, verify: { runtime in
            #expect(runtime === old)
            if networkError { throw URLError(.timedOut) }
            return try browserContext()
        })
        let payload = try browserPayload([browserCookie("__Secure-next-auth.session-token", value: "remote")])
        if networkError {
            await #expect(throws: URLError.self) { try await adoption.prepare(payload, for: profile) }
        } else {
            let result = try await adoption.prepare(payload, for: profile)
            #expect(result.webDataStoreID == profile.webDataStoreID)
            try adoption.commit(profileID: profile.id)
        }
        #expect(await old.sessionStore.cookieValue(named: "__Secure-next-auth.session-token") == "local")
        await adoption.discard(profileID: profile.id)
        try? await registry.removeProfileData(for: profile)
    }
    @Test func cdpCookieParametersPreserveFlagsAndOmitSessionExpiry() async throws {
        var observed: [[String: Any]] = []
        let client = ChromeDevToolsClient(request: { bytes in
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            observed.append(object)
            return try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": [:]])
        })
        let persistent = browserCookie("persistent", expires: Date(timeIntervalSince1970: 4_000_000_000))
        let session = browserCookie("__Secure-next-auth.session-token")
        try await client.setCookies([persistent, session, browserCookie("old", expires: .distantPast)])
        let call = try #require(observed.first)
        #expect(call["method"] as? String == "Storage.setCookies")
        let params = try #require(call["params"] as? [String: Any])
        let cookies = try #require(params["cookies"] as? [[String: Any]])
        #expect(cookies.count == 2)
        let savedSession = try #require(cookies.first { $0["name"] as? String == session.name })
        #expect(savedSession["expires"] == nil)
        #expect(savedSession["secure"] as? Bool == true)
        #expect(savedSession["httpOnly"] as? Bool == true)
        #expect(savedSession["path"] as? String == "/")
        #expect(savedSession["sameSite"] as? String == "Lax")
        #expect(cookies.first { $0["name"] as? String == "persistent" }?["expires"] as? Double == 4_000_000_000)
    }

    @Test func unsupportedCookieNeverReachesCDP() async throws {
        let client = ChromeDevToolsClient(request: { _ in Issue.record("Invalid cookie was sent"); return Data() })
        var cookie = browserCookie("__Secure-next-auth.session-token"); cookie.domain = "other.example"
        await #expect(throws: CloudSessionError.invalidPayload) { try await client.setCookies([cookie]) }
    }

    @Test(arguments: [false, true])
    func prepareUsesFreshStoreAndRetainsSessionOnlyCookiesAfterCommit(chunked: Bool) async throws {
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry()
        let old = registry.runtime(for: profile)
        let previous = browserCookie(chunked ? "__Secure-next-auth.session-token" : "__Secure-next-auth.session-token.0", value: "previous")
        await old.sessionStore.storeCookies([try #require(previous.cookie)])
        let cookies = [browserCookie(chunked ? "__Secure-next-auth.session-token.0" : "__Secure-next-auth.session-token", value: "incoming"),
                       browserCookie("expired", expires: .distantPast)]
        let context = try browserContext()
        let adoption = CloudBrowserSessionAdoption(registry: registry, verify: { runtime in
            if runtime === old { throw ChatGPTAPIError.unauthorized }
            #expect(runtime !== old)
            #expect(await runtime.sessionStore.cookieValue(named: cookies[0].name) == "incoming")
            #expect(await runtime.sessionStore.cookieValue(named: previous.name) == nil)
            return context
        })
        let fresh = try await adoption.prepare(browserPayload(cookies), for: profile)
        #expect(fresh.id == profile.id)
        #expect(fresh.webDataStoreID != profile.webDataStoreID)
        #expect(registry.runtime(for: profile) === old)
        #expect(await old.sessionStore.cookieValue(named: previous.name) == "previous")
        try adoption.commit(profileID: profile.id)
        let adopted = registry.runtime(for: fresh)
        #expect(await adopted.sessionStore.cookieValue(named: cookies[0].name) == "incoming")
        #expect(await adopted.sessionStore.cookieValue(named: "expired") == nil)
        #expect(adopted.authContext == context)
        await old.sessionStore.clear(); try? await registry.removeProfileData(for: profile)
        try? await registry.removeProfileData(for: fresh)
    }

    @Test(arguments: ["domain", "account", "user", "cancel"])
    func failedValidationLeavesOldRuntimeUnchanged(reason: String) async throws {
        let profile = CodexSignInFixture.profile(), registry = ProfileRuntimeRegistry(), old = registry.runtime(for: profile)
        let cookie = browserCookie("__Secure-next-auth.session-token", value: "original")
        await old.sessionStore.storeCookies([try #require(cookie.cookie)])
        let adoption = CloudBrowserSessionAdoption(registry: registry, verify: { runtime in
            if runtime === old { throw ChatGPTAPIError.unauthorized }
            if reason == "cancel" { throw CancellationError() }
            return try browserContext(account: reason == "account" ? "wrong" : "workspace", user: reason == "user" ? "wrong" : "user")
        })
        var incoming = browserCookie("__Secure-next-auth.session-token", value: "new")
        if reason == "domain" { incoming.domain = "evil.example" }
        do { _ = try await adoption.prepare(browserPayload([incoming]), for: profile); Issue.record("Invalid session accepted") }
        catch { }
        await adoption.discard(profileID: profile.id)
        #expect(registry.runtime(for: profile) === old)
        #expect(await old.sessionStore.cookieValue(named: cookie.name) == "original")
        try? await registry.removeProfileData(for: profile)
    }
}

/// Rebase the real default's full Application Support layout, rather than replacing
/// it with an arbitrary "seeds" folder that bypasses production path validation.
final class CloudBrowserSeedTestStorage {
    let root: URL
    let store: CloudBrowserSeedStore

    init() throws {
        let support = ProfileCatalogStore.defaultFileURL().deletingLastPathComponent().deletingLastPathComponent()
        let productionPath = CloudBrowserSeedStore().directory.path
        let prefix = support.path + "/"
        try #require(productionPath.hasPrefix(prefix))
        root = try CodexSignInFixture.directory()
        store = CloudBrowserSeedStore(directory: root.appendingPathComponent("Library/Application Support")
            .appendingPathComponent(String(productionPath.dropFirst(prefix.count))))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

func browserCookie(_ name: String, value: String = "synthetic", expires: Date? = nil) -> BackupCookie {
    .init(name: name, value: value, domain: "chatgpt.com", path: "/", secure: true, httpOnly: true, expires: expires, sameSite: "Lax")
}

func browserPayload(_ cookies: [BackupCookie]) throws -> CloudSessionPayload {
    let signIn = try CodexSignIn(data: CodexSignInFixture.data(refresh: UUID().uuidString))
    return .browser(cookies: cookies, identity: .init(accountID: "workspace", userID: "user"), accessToken: signIn.accessToken)
}

func browserContext(account: String = "workspace", user: String = "user") throws -> ChatGPTAuthContext {
    let signIn = try CodexSignIn(data: CodexSignInFixture.data(account: account, user: user, refresh: UUID().uuidString))
    let data = try JSONSerialization.data(withJSONObject: ["accessToken": signIn.accessToken, "account": ["id": account], "user": ["id": user]])
    return try AuthSessionService.decodeAuthContext(from: data)
}

@MainActor final class BrowserAdoptionResult { var profile: PlusProfile? }

@MainActor struct BrowserAdoptionTransport: HTTPTransport {
    let store: WebSessionStore
    let wrongUser: Bool
    func data(for request: URLRequest) async throws -> HTTPResponseData {
        let url = try #require(request.url)
        if url.path != "/api/auth/session" { throw URLError(.notConnectedToInternet) }
        #expect(await store.cookieValue(named: "__Secure-next-auth.session-token") == "incoming")
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "__Secure-next-auth.session-token=response; Path=/; Secure; HttpOnly; SameSite=Lax"]))
        await store.storeResponseCookies(from: response, for: url)
        let context = try browserContext(user: wrongUser ? "other" : "user")
        let data = try JSONSerialization.data(withJSONObject: ["accessToken": context.accessToken,
            "account": ["id": "workspace"], "user": ["id": wrongUser ? "other" : "user"]])
        return .init(data: data, response: response)
    }
}

@MainActor final class BrowserSeedChromeSpy: ChromeSessionManaging {
    var seeds = 0, opens = 0
    var failSeed = false
    func seedCookies(_ cookies: [BackupCookie], for profile: PlusProfile) async throws {
        seeds += 1
        if failSeed { throw CloudSessionError.unavailable }
    }
    func openAccountPage(for profile: PlusProfile) async throws { opens += 1 }
    func openSignIn(for profile: PlusProfile) async throws {}
    func openPasskeySetup(for profile: PlusProfile) async throws {}
    func syncCookies(for profile: PlusProfile, into sessionStore: WebSessionStore) async throws -> ChromeCookieImportResult { .init(importedCookieCount: 0) }
    func waitForSignInToFinish(for profile: PlusProfile) async -> Bool { false }
    func clearCookies(for profile: PlusProfile) async throws {}
    func removeProfileData(for profile: PlusProfile) async throws {}
    func closeSignIn(for profile: PlusProfile) async {}
}
