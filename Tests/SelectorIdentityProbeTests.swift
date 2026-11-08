import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

/// Explicitly opt-in, read-only evidence collection. No normal app startup or native
/// credential API is used. Only fixed identity fields leave this process.
struct SelectorIdentityProbeTests {
    @Test
    func projectionRetainsIdentityRelationshipsWithoutPrivateValues() throws {
        let projection = BrowserIdentityProjection(
            session: ["account": ["id": "private-account"], "user": ["id": "private-user", "email": "private-email"],
                      "accessToken": "private-token", "secret": "private-secret"],
            claims: ["sub": "private-other", "https://api.openai.com/auth": ["user_id": "private-user"]],
            accountID: "private-account", userID: "private-user"
        )
        let encoded = try JSONEncoder().encode(projection)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("private-"))
        #expect(projection.fields["session.user.id"] == "native-user")
        #expect(projection.fields["claims.sub"] == "other-identity")
        #expect(projection.fields["claims.auth.user_id"] == "native-user")
        #expect(projection.accountMatched)
        #expect(projection.userMatched)
    }

    @Test
    func projectionDoesNotInferMissingBrowserUserFromSavedIdentity() {
        let projection = BrowserIdentityProjection(
            session: ["account": ["id": "a"], "user": ["email": "same@example.invalid"]],
            claims: [:], accountID: "a", userID: "u"
        )
        #expect(projection.accountMatched)
        #expect(!projection.userMatched)
        #expect(projection.fields["session.user.id"] == "absent")
    }

    @Test
    func projectionDoesNotTreatSubjectAsCanonicalBrowserUser() {
        let projection = BrowserIdentityProjection(
            session: ["account": ["id": "a"]], claims: ["sub": "u"], accountID: "a", userID: "u"
        )
        #expect(!projection.userMatched)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SELECTOR_IDENTITY_PROBE"] == "1"))
    @MainActor
    func authorizedBrowserIdentityEvidence() async throws {
        // Failures contain only stable codes; never interpolate a profile, response,
        // URLSession error, cookie, token, or JWT payload into a Testing assertion.
        guard let output = ProcessInfo.processInfo.environment["SELECTOR_IDENTITY_REPORT_DIRECTORY"] else {
            throw IdentityProbeError.outputMissing
        }
        let reportDirectory = URL(fileURLWithPath: output, isDirectory: true)
        guard reportDirectory.path.contains("/expiry-selector/build/") else { throw IdentityProbeError.outputMissing }
        let file = ProfileCatalogStore.defaultFileURL()
        let profiles: [IdentityProbeProfile]
        do {
            profiles = try JSONDecoder().decode([IdentityProbeProfile].self, from: Data(contentsOf: file))
        } catch { throw IdentityProbeError.catalogReadFailed }
        let candidates = profiles.filter { ($0.provider ?? "codex") == "codex" && $0.openCodeOpenAIAccount != nil && $0.lastKnownState == "active" }
            .sorted { ($0.lastRefreshAt ?? .distantPast) > ($1.lastRefreshAt ?? .distantPast) }
        guard !candidates.isEmpty else { throw IdentityProbeError.noActiveBoundProfiles }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        let client = URLSession(configuration: configuration, delegate: IdentityProbeRedirectGuard(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        var reports: [BrowserIdentityProbeReport] = []
        // Two profiles supply independent representative shapes, without a broad account sweep.
        for profile in candidates.prefix(2) {
            guard let native = profile.openCodeOpenAIAccount else { continue }
            let store = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
            let sessions = WebSessionStore(dataStore: store)
            do {
                let data = try await probeRequest(AuthSessionService.makeCurrentSessionRequest(), store: sessions, client: client)
                let root = try probeObject(data)
                let session = (root["session"] as? [String: Any]) ?? root
                let claims = decodeProbeClaims(session["accessToken"] as? String)
                let projection = BrowserIdentityProjection(session: session, claims: claims, accountID: native.accountID, userID: native.userID)
                // Use the existing production session decoder and signer for the same GET
                // account-catalog route used by refresh. No response cookies are stored.
                let context: ChatGPTAuthContext
                do { context = try AuthSessionService.decodeAuthContext(from: data) }
                catch { throw IdentityProbeError.sessionUnavailable }
                let catalogData = try await probeRequest(AccountCatalogService.makeRequest(), store: sessions, client: client, context: context)
                let decoded: AccountCatalogService.Catalog
                do { decoded = try AccountCatalogService.decodeCatalogEvidence(from: catalogData) }
                catch { throw IdentityProbeError.catalogUnavailable }
                let matched = decoded.displayItems.filter { $0.accountID == native.accountID }
                let evidence = decoded.evidenceItems.filter { $0.accountID == native.accountID }
                let rawCatalog = try probeObject(catalogData)
                let accounts = rawCatalog["accounts"] as? [String: Any] ?? [:]
                let matchingRows = accounts.values.compactMap { $0 as? [String: Any] }.filter { row in
                    let account = row["account"] as? [String: Any] ?? [:]
                    return (account["account_id"] as? String ?? account["id"] as? String) == native.accountID
                }
                let matchingPayloads = try matchingRows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                let row = matchingRows.first ?? [:]
                let entitlement = row["entitlement"] as? [String: Any] ?? [:]
                let rawAccount = row["account"] as? [String: Any] ?? [:]
                reports.append(BrowserIdentityProbeReport(
                    projection: projection, outcome: "observed", canonicalCatalogMatches: matched.count,
                    catalogFields: [
                        "account.account_id": fieldShape(rawAccount["account_id"]),
                        "account.id": fieldShape(rawAccount["id"]),
                        "account.account_user_id": fieldShape(rawAccount["account_user_id"]),
                        "account.account_owner_id": fieldShape(rawAccount["account_owner_id"]),
                        "account.is_deactivated": fieldShape(rawAccount["is_deactivated"]),
                        "can_access_with_session": fieldShape(row["can_access_with_session"]),
                        "entitlement.expires_at": fieldShape(entitlement["expires_at"]),
                        "entitlement.has_active_subscription": fieldShape(entitlement["has_active_subscription"]),
                        "raw.canonicalMatches": String(matchingRows.count),
                        "raw.duplicateRowsEqual": String(matchingPayloads.count == 2 && matchingPayloads[0] == matchingPayloads[1]),
                        "evidence.canonicalMatches": String(evidence.count),
                        "evidence.validRows": String(evidence.filter { $0.selectorEvidence?.valid == true }.count),
                        "evidence.expiryRows": String(evidence.filter { $0.expiresAt != nil }.count),
                        "evidence.explicitFlagsRows": String(evidence.filter { $0.selectorEvidence?.deactivated != nil && $0.selectorEvidence?.usable != nil }.count)
                    ]
                ))
            } catch {
                // No raw networking diagnostics enter disk or test output.
                let code = (error as? IdentityProbeError)?.rawValue ?? "probe-failed"
                reports.append(.init(projection: nil, outcome: code, canonicalCatalogMatches: 0, catalogFields: [:]))
            }
        }
        let report = BrowserIdentityProbeEnvelope(schemaVersion: 1, authorization: "explicit-user-approval",
            generatedAtMs: Int64(Date().timeIntervalSince1970 * 1000), profiles: reports)
        do {
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let reportFile = reportDirectory.appendingPathComponent("report.json")
            try encoder.encode(report).write(to: reportFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportFile.path)
        } catch { throw IdentityProbeError.outputFailed }
        let established = reports.contains { $0.projection?.accountMatched == true && $0.projection?.userMatched == true && $0.canonicalCatalogMatches == 1 }
        #expect(established, "Browser account+user evidence unavailable; inspect the sanitized report.")
    }
}

private struct IdentityProbeProfile: Decodable {
    let provider: String?
    let webDataStoreID: UUID
    let openCodeOpenAIAccount: IdentityProbeNativeIdentity?
    let lastKnownState: String
    let lastRefreshAt: Date?
}

private struct IdentityProbeNativeIdentity: Decodable {
    let accountID: String
    let userID: String
}

private struct BrowserIdentityProbeEnvelope: Encodable {
    let schemaVersion: Int
    let authorization: String
    let generatedAtMs: Int64
    let profiles: [BrowserIdentityProbeReport]
}

private struct BrowserIdentityProbeReport: Encodable {
    let projection: BrowserIdentityProjection?
    let outcome: String
    let canonicalCatalogMatches: Int
    let catalogFields: [String: String]
}

private struct BrowserIdentityProjection: Encodable {
    let fields: [String: String]
    let accountMatched: Bool
    let userMatched: Bool

    init(session: [String: Any], claims: [String: Any], accountID: String, userID: String) {
        let account = session["account"] as? [String: Any] ?? [:]
        let user = session["user"] as? [String: Any] ?? [:]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let inputs: [String: Any?] = [
            "session.account.id": account["id"], "session.account.account_id": account["account_id"],
            "session.user.id": user["id"], "session.user.user_id": user["user_id"],
            "claims.sub": claims["sub"], "claims.user_id": claims["user_id"],
            "claims.auth.chatgpt_account_id": auth["chatgpt_account_id"],
            "claims.auth.chatgpt_user_id": auth["chatgpt_user_id"], "claims.auth.user_id": auth["user_id"]
        ]
        var fields: [String: String] = [:]
        for (path, value) in inputs {
            guard let text = value as? String, !text.isEmpty else { fields[path] = fieldShape(value); continue }
            fields[path] = text == accountID ? "native-account" : text == userID ? "native-user" : "other-identity"
        }
        self.fields = fields
        self.accountMatched = fields["session.account.id"] == "native-account" || fields["session.account.account_id"] == "native-account"
        self.userMatched = ["session.user.id", "session.user.user_id", "claims.auth.chatgpt_user_id", "claims.auth.user_id", "claims.user_id"]
            .contains { fields[$0] == "native-user" }
    }
}

private enum IdentityProbeError: String, Error {
    case outputMissing = "output-missing", outputFailed = "output-failed"
    case catalogReadFailed = "catalog-read-failed", noActiveBoundProfiles = "no-active-bound-profiles"
    case sessionUnavailable = "session-unavailable", catalogUnavailable = "catalog-unavailable"
    case invalidRoute = "invalid-route", transportFailed = "transport-failed", responseUnavailable = "response-unavailable"
    case responseTooLarge = "response-too-large", invalidJSON = "invalid-json"
}

private final class IdentityProbeRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
private func probeRequest(_ input: URLRequest, store: WebSessionStore, client: URLSession,
                          context: ChatGPTAuthContext? = nil) async throws -> Data {
    guard let url = input.url, url.scheme == "https", url.host == "chatgpt.com", url.port == nil,
          ["/api/auth/session", "/backend-api/accounts/check/v4-2023-04-27"].contains(url.path),
          input.httpMethod == nil || input.httpMethod == "GET" else { throw IdentityProbeError.invalidRoute }
    let cookies = await store.cookies(for: url)
    let signed = ChatGPTRequestSigner.sign(input, cookies: cookies, authContext: context)
    do {
        let (bytes, response) = try await client.bytes(for: signed)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw IdentityProbeError.responseUnavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw IdentityProbeError.responseTooLarge }
            data.append(byte)
        }
        return data
    } catch let error as IdentityProbeError { throw error }
    catch { throw IdentityProbeError.transportFailed }
}

private func probeObject(_ data: Data) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IdentityProbeError.invalidJSON }
    return value
}

private func decodeProbeClaims(_ token: String?) -> [String: Any] {
    guard let token else { return [:] }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[1].count < 32_768 else { return [:] }
    var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return [:] }
    return (try? probeObject(data)) ?? [:]
}

private func fieldShape(_ value: Any?) -> String {
    guard let value else { return "absent" }
    if value is NSNull { return "null" }
    if value is String { return "string" }
    if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number" }
    return "other-type"
}
