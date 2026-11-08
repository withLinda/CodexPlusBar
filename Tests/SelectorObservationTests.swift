import Foundation
import Testing
@testable import CodexPlusBar

struct SelectorObservationTests {
    private let native = OpenCodeOpenAIIdentity(accountID: "account-a", userID: "user-a", email: "same@example.test")
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: ["user-b", ""])
    func sameEmailCannotSubstituteForMatchingBrowserUser(_ user: String) throws {
        let result = try observation(user: user)
        #expect(result.usage == nil)
        #expect(result.entitlement == nil)
        #expect(result.unavailableReasons.contains("identity-mismatch"))
    }

    @Test
    func browserAccountMustMatchNativeAndUsageAccount() throws {
        #expect(try observation(account: "account-b").usage == nil)
        #expect(try observation(usageAccount: "account-b").usage == nil)
        #expect(try observation().usage?.identityKey == native.storageKey)
    }

    @Test
    func aliasRequiresOneCanonicalCatalogMatch() throws {
        let matched = try observation(account: "alias-a", usageAccount: "alias-a", catalog: catalog(alias: "alias-a"))
        #expect(matched.usage?.identityKey == native.storageKey)
        #expect(matched.entitlement?.match == .uniqueAlias)
        let ambiguous = try catalog(alias: "alias-a") + catalog(account: "account-b", alias: "alias-a")
        #expect(try observation(account: "alias-a", usageAccount: "alias-a", catalog: ambiguous).usage == nil)
        let duplicate = try catalog() + catalog()
        #expect(try observation(catalog: duplicate).entitlement == nil)
    }

    @Test
    func defaultCatalogCannotProvideAutomationExpiry() throws {
        let result = try observation(catalog: catalog(account: "account-b", key: "default"))
        #expect(result.usage != nil)
        #expect(result.entitlement == nil)
        #expect(result.unavailableReasons.contains("expiry-unknown"))
    }

    @Test
    func identicalDefaultMirrorPreservesVerifiedExpiryAndAliasIdentity() throws {
        let raw = try mirroredCatalog()
        let decoded = try AccountCatalogService.decodeCatalogEvidence(from: raw)
        let result = try observation(catalog: decoded.evidenceItems)
        #expect(result.entitlement?.expiresAt == Date(timeIntervalSince1970: 1_811_808_000))
        #expect(result.entitlement?.observedAt == time)
        #expect(result.unavailableReasons.isEmpty)
        #expect(try observation(account: "alias-a", usageAccount: "alias-a", catalog: decoded.evidenceItems).entitlement?.match == .uniqueAlias)
    }

    @Test(arguments: ["expiry", "active", "usable", "numeric-flag", "deactivated", "missing-flag", "extra-field", "different-account"])
    func differingDefaultMirrorCannotSupplyAutomationExpiry(_ difference: String) throws {
        let decoded = try AccountCatalogService.decodeCatalogEvidence(from: mirroredCatalog(difference: difference))
        if difference == "different-account" {
            // An unrelated default must not replace the canonical account's explicit unknown expiry.
            #expect(try observation(catalog: decoded.evidenceItems).entitlement?.expiresAt == nil)
        } else {
            #expect(try observation(catalog: decoded.evidenceItems).entitlement == nil)
        }
    }

    @Test(arguments: ["noncanonical-key", "missing-explicit-id"])
    func identicalRowsWithoutCanonicalMirrorIdentityRemainSeparate(_ boundary: String) throws {
        var row: [String: Any] = [
            "account": ["account_id": "account-a", "is_deactivated": false],
            "can_access_with_session": true,
            "entitlement": ["expires_at": "2027-06-01T00:00:00Z", "has_active_subscription": true]
        ]
        if boundary == "missing-explicit-id" { row["account"] = ["is_deactivated": false] }
        let key = boundary == "noncanonical-key" ? "unrelated-key" : "account-a"
        let data = try JSONSerialization.data(withJSONObject: ["accounts": [key: row, "default": row]])
        let decoded = try AccountCatalogService.decodeCatalogEvidence(from: data)
        #expect(decoded.evidenceItems.count == 2)
        if boundary == "noncanonical-key" {
            #expect(try observation(catalog: decoded.evidenceItems).entitlement == nil)
        } else {
            #expect(Set(decoded.evidenceItems.map(\.accountID)) == ["account-a", "default"])
        }
    }

    private func mirroredCatalog(difference: String? = nil) throws -> Data {
        var canonical: [String: Any] = [
            "account": ["account_id": "account-a", "account_user_id": "alias-a", "is_deactivated": false],
            "can_access_with_session": true,
            "entitlement": ["expires_at": "2027-06-01T00:00:00Z", "has_active_subscription": true]
        ]
        var mirror = canonical
        switch difference {
        case "expiry": mirror["entitlement"] = ["expires_at": "2027-06-02T00:00:00Z", "has_active_subscription": true]
        case "active": mirror["entitlement"] = ["expires_at": "2027-06-01T00:00:00Z", "has_active_subscription": false]
        case "usable": mirror["can_access_with_session"] = false
        case "numeric-flag": mirror["can_access_with_session"] = 1
        case "deactivated": mirror["account"] = ["account_id": "account-a", "account_user_id": "alias-a", "is_deactivated": true]
        case "missing-flag": mirror.removeValue(forKey: "can_access_with_session")
        case "extra-field": mirror["unknown_access_field"] = false
        case "different-account":
            canonical["entitlement"] = ["expires_at": NSNull(), "has_active_subscription": true]
            mirror["account"] = ["account_id": "account-b", "is_deactivated": false]
        default: break
        }
        return try JSONSerialization.data(withJSONObject: ["accounts": ["account-a": canonical, "default": mirror]])
    }

    @Test
    func explicitNullExpiryIsNewUnknownEvidence() throws {
        let result = try observation(catalog: catalog(expiry: "null"))
        let entitlement = try #require(result.entitlement)
        #expect(entitlement.expiresAt == nil)
        #expect(entitlement.observedAt == time)
    }

    @Test
    func failedExpiryFetchDoesNotInventObservationTimestamp() throws {
        let previous = try observation()
        let failed = try observation(catalog: .some(nil))
        #expect(previous.entitlement?.observedAt == time)
        #expect(failed.entitlement == nil)
        #expect(failed.usage != nil)
        #expect(failed.unavailableReasons.contains("expiry-refresh-failed"))
    }

    @Test(arguments: ["101", "-1", "0.5", "true", "\"25\""])
    func displayClampDoesNotMakeRawPercentageTrusted(_ percent: String) throws {
        let snapshot = try usage(percent: percent)
        #expect((0...100).contains(snapshot.primaryWindow.usedPercent))
        #expect(try observation(snapshot: snapshot).usage == nil)
    }

    @Test(arguments: ["", ",\"secondary_window\":false"])
    func omittedOrMalformedWeeklyWindowIsUnknown(_ weekly: String) throws {
        #expect(try observation(snapshot: usage(weekly: weekly)).usage == nil)
    }

    @Test
    func malformedWeeklyObjectStillRejectsTheDisplayResponse() {
        #expect(throws: ChatGPTAPIError.self) { try usage(weekly: ",\"secondary_window\":{}") }
    }

    @Test
    func nullWeeklyIsNotApplicableAndFlagsRemainExplicit() throws {
        let result = try observation()
        #expect(result.usage?.sevenDay == .notApplicable)
        #expect(result.usage?.fiveHour.remainingPercent == 75)
        #expect(try observation(snapshot: usage(flags: "\"allowed\":false,\"limit_reached\":false,")).usage?.allowed == false)
        #expect(try observation(snapshot: usage(flags: "\"allowed\":true,\"limit_reached\":true,")).usage?.limitReached == true)
        #expect(try observation(snapshot: usage(flags: "")).usage == nil)
        #expect(try observation(snapshot: usage(flags: "\"allowed\":1,\"limit_reached\":0,")).usage == nil)
    }

    @Test
    func catalogDisplayDefaultsAreNotEvidence() throws {
        #expect(try observation(catalog: catalog(flags: "")).entitlement == nil)
        #expect(try observation(catalog: catalog(expiry: "\"bad-date\"")).entitlement == nil)
    }

    @Test
    func conflictingCatalogAccountFieldsCannotGrantExpiry() throws {
        let raw = Data(#"{"accounts":{"a":{"account":{"account_id":"account-a","id":"account-b","is_deactivated":false},"can_access_with_session":true,"entitlement":{"expires_at":"2027-06-01T00:00:00Z"}}}}"#.utf8)
        let catalog = try AccountCatalogService.decodeCatalogEvidence(from: raw)
        #expect(try observation(catalog: catalog.evidenceItems).entitlement == nil)
    }

    @Test
    func weeklyEvidenceKeepsItsOwnQuotaAndReset() throws {
        let snapshot = try usage(weekly: #", "secondary_window":{"used_percent":60,"reset_at":1800086400,"limit_window_seconds":604800}"#)
        let result = try observation(snapshot: snapshot)
        #expect(result.usage?.sevenDay == .available(SelectorQuotaWindow(remainingPercent: 40, resetAt: Date(timeIntervalSince1970: 1_800_086_400))))
        #expect(try observation(snapshot: usage(weekly: #", "secondary_window":{"used_percent":101,"reset_at":1800086400}"#)).usage == nil)
    }

    @Test
    func sessionUserUsesCurrentCanonicalEvidenceAndNeverSubjectOrFallback() throws {
        let fallback = context(user: "user-a")
        let missing = try AuthSessionService.decodeAuthContext(
            from: Data(#"{"account":{"id":"account-a"},"accessToken":"opaque"}"#.utf8), fallback: fallback)
        #expect(missing.userID == nil)
        let token = try jwt(["sub": "user-a", "https://api.openai.com/auth": ["chatgpt_user_id": "user-b"]])
        let claims = try AuthSessionService.decodeAuthContext(from: session(token: token))
        #expect(claims.userID == "user-b")
        let conflict = try AuthSessionService.decodeAuthContext(from: session(token: token, user: "user-a"))
        #expect(conflict.userID == nil)
        let subject = try AuthSessionService.decodeAuthContext(from: session(token: jwt(["sub": "user-a"])))
        #expect(subject.userID == nil)
        #expect(try AuthSessionService.decodeAuthContext(from: session(token: "opaque", user: "user-a")).userID == "user-a")
    }

    @Test
    func tokenAccountConflictAndMissingPayloadAccountCannotBorrowHeader() throws {
        let token = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "account-b", "chatgpt_user_id": "user-a"]])
        let result = SelectorObservation.make(context: context(token: token), snapshot: try usage(),
            catalog: try catalog(), entitlementObservedAt: time, nativeIdentity: native)
        #expect(result?.usage == nil)
        #expect(try observation(snapshot: usage(account: nil)).usage == nil)
    }

    private func context(account: String = "account-a", user: String = "user-a", token: String = "opaque") -> ChatGPTAuthContext {
        ChatGPTAuthContext(accessToken: token, accountID: account, expiresAt: nil, deviceID: nil,
            clientVersion: nil, language: "en-US", userID: user.isEmpty ? nil : user)
    }

    private func observation(account: String = "account-a", user: String = "user-a", usageAccount: String = "account-a",
                             snapshot: WorkspaceLimitSnapshot? = nil, catalog: [AccountCatalogItem]?? = nil) throws -> SelectorObservation {
        try #require(SelectorObservation.make(context: context(account: account, user: user),
            snapshot: try snapshot ?? usage(account: usageAccount),
            catalog: try catalog ?? self.catalog(), entitlementObservedAt: time, nativeIdentity: native))
    }

    private func usage(account: String? = "account-a", percent: String = "25",
                       flags: String = "\"allowed\":true,\"limit_reached\":false,",
                       weekly: String = ",\"secondary_window\":null") throws -> WorkspaceLimitSnapshot {
        let accountField = account.map { "\"account_id\":\"\($0)\"," } ?? ""
        return try WorkspaceLimitService.decodeSnapshot(from: Data("""
            {\(accountField)"plan_type":"plus","rate_limit":{\(flags)
            "primary_window":{"used_percent":\(percent),"reset_at":1800003600}\(weekly)}}
            """.utf8), workspaceID: "account-a")
    }

    private func catalog(account: String = "account-a", alias: String = "alias-unused", key: String = "entry",
                         expiry: String = "\"2027-06-01T00:00:00Z\"",
                         flags: String = "\"can_access_with_session\":true,") throws -> [AccountCatalogItem] {
        try AccountCatalogService.decodeCatalogEvidence(from: Data("""
            {"accounts":{"\(key)":{\(flags)"account":{"account_id":"\(account)","account_user_id":"\(alias)","is_deactivated":false},
            "entitlement":{"expires_at":\(expiry),"has_active_subscription":true}}}}
            """.utf8)).evidenceItems
    }

    private func jwt(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture.\(payload).signature"
    }

    private func session(token: String, user: String? = nil) throws -> Data {
        var object: [String: Any] = ["account": ["id": "account-a"], "accessToken": token]
        if let user { object["user"] = ["id": user] }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
