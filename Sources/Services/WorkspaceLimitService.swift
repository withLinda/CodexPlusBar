import Foundation

struct WorkspaceLimitService {
    fileprivate static let traceHint =
        "Rerun with TRACE_PRIVATE_API=1 and refresh once to inspect /backend-api/wham/usage."

    static func decodeSnapshot(from data: Data, workspaceID: String) throws -> WorkspaceLimitSnapshot {
        switch WorkspacePayloadSupport.inspectPayload(in: data) {
        case .html, .unauthorizedJSON:
            throw ChatGPTAPIError.unauthorized
        case let .json(payload):
            return try normalizeSnapshot(from: payload, workspaceID: workspaceID)
        case .empty:
            throw ChatGPTAPIError.unsupported(
                "ChatGPT returned no limit data for this account. \(traceHint)"
            )
        case .unrecognized:
            throw ChatGPTAPIError.unsupported(
                "ChatGPT returned limit data for this account, but the format changed and the app could not read it. \(traceHint)"
            )
        }
    }

    private static func normalizeSnapshot(from payload: Any, workspaceID: String) throws -> WorkspaceLimitSnapshot {
        if let rootObject = payload as? JSONObject, rootObject["rate_limit"] != nil {
            return try snapshot(
                from: rootObject,
                workspaceID: workspaceID,
                accountID: WorkspacePayloadSupport.firstNonEmptyString(
                    from: rootObject["account_id"],
                    rootObject["id"],
                    workspaceID
                ) ?? workspaceID
            )
        }

        let collection = try WorkspacePayloadSupport.extractCollection(from: payload, traceHint: traceHint)
        guard let matchedEntry = collection.entries.first(where: {
            WorkspacePayloadSupport.resolveWorkspaceID(from: $0) == workspaceID
        }) else {
            throw ChatGPTAPIError.unsupported(
                "ChatGPT returned limits for other workspaces, but not the selected workspace. \(traceHint)"
            )
        }

        return try snapshot(from: matchedEntry, workspaceID: workspaceID)
    }

    private static func snapshot(from entry: WorkspaceEntry, workspaceID: String) throws -> WorkspaceLimitSnapshot {
        guard let object = entry.payload as? JSONObject else {
            throw unsupportedAuthenticatedResponse()
        }

        let accountID = WorkspacePayloadSupport.resolveWorkspaceID(from: entry) ?? workspaceID
        return try snapshot(from: object, workspaceID: workspaceID, accountID: accountID, payloadAccountID: accountID)
    }

    private static func snapshot(from object: JSONObject, workspaceID: String, accountID: String,
                                 payloadAccountID: String? = nil) throws -> WorkspaceLimitSnapshot {
        let accountObject = (object["account"] as? JSONObject) ?? object
        let planType = WorkspacePayloadSupport.firstNonEmptyString(
            from: accountObject["plan_type"],
            accountObject["planType"],
            object["plan_type"],
            object["planType"]
        ) ?? "unknown"

        guard let rateLimitPayload = rateLimitObject(named: "rate_limit", in: object) else {
            throw unsupportedAuthenticatedResponse()
        }

        let rateLimit = try RateLimitContainer(object: rateLimitPayload)
        let explicitIDs = [accountObject["account_id"], accountObject["id"], object["account_id"], object["id"]]
            .compactMap { $0 as? String }.filter { !$0.isEmpty }
        let evidenceAccountID = Set(explicitIDs).count > 1 ? nil : explicitIDs.first ?? payloadAccountID

        return WorkspaceLimitSnapshot(
            workspaceID: workspaceID,
            accountID: accountID,
            planType: planType,
            primaryWindow: try rateLimit.primaryWindow.requireWindow(),
            secondaryWindow: try rateLimit.secondaryWindow?.requireWindow(),
            fetchedAt: .now,
            selectorEvidence: SelectorUsageEvidence(accountID: evidenceAccountID,
                allowed: SelectorIdentityEvidence.bool(rateLimitPayload["allowed"]),
                limitReached: SelectorIdentityEvidence.bool(rateLimitPayload["limit_reached"]),
                fiveHour: rateLimit.primaryWindow.selectorWindow(expectedDuration: 18_000),
                sevenDay: rateLimit.sevenDay)
        )
    }

    private static func rateLimitObject(named key: String, in object: JSONObject) -> JSONObject? {
        if let candidate = object[key] as? JSONObject, hasUsablePrimaryWindow(in: candidate) {
            return candidate
        }

        for value in object.values {
            if let candidate = findNestedRateLimitObject(named: key, in: value) {
                return candidate
            }
        }

        return nil
    }

    private static func findNestedRateLimitObject(named key: String, in value: Any) -> JSONObject? {
        if let object = value as? JSONObject {
            for (nestedKey, nestedValue) in object {
                guard nestedKey == key,
                      let candidate = nestedValue as? JSONObject,
                      hasUsablePrimaryWindow(in: candidate) else {
                    continue
                }

                return candidate
            }

            for nestedValue in object.values {
                if let candidate = findNestedRateLimitObject(named: key, in: nestedValue) {
                    return candidate
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let candidate = findNestedRateLimitObject(named: key, in: item) {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func hasUsablePrimaryWindow(in object: JSONObject) -> Bool {
        guard let primaryWindow = object["primary_window"] as? JSONObject,
              let resetAt = WorkspacePayloadSupport.intValue(from: primaryWindow["reset_at"]),
              resetAt > 0 else {
            return false
        }

        return true
    }

    fileprivate static func unsupportedAuthenticatedResponse() -> ChatGPTAPIError {
        ChatGPTAPIError.unsupported(
            "ChatGPT returned limit data for this account, but the format changed and the app could not read it. \(traceHint)"
        )
    }
}

private struct RateLimitContainer {
    let primaryWindow: LimitWindowPayload
    let secondaryWindow: LimitWindowPayload?
    let sevenDay: SelectorSevenDay

    init(object: JSONObject) throws {
        guard let primaryWindowObject = object["primary_window"] as? JSONObject else {
            throw WorkspaceLimitService.unsupportedAuthenticatedResponse()
        }

        primaryWindow = try LimitWindowPayload(object: primaryWindowObject)
        if let secondaryWindowObject = object["secondary_window"] as? JSONObject {
            secondaryWindow = try LimitWindowPayload(object: secondaryWindowObject)
            sevenDay = secondaryWindow?.selectorWindow(expectedDuration: 604_800).map(SelectorSevenDay.available) ?? .unknown
        } else {
            secondaryWindow = nil
            sevenDay = object["secondary_window"] is NSNull ? .notApplicable : .unknown
        }
    }
}

private struct LimitWindowPayload {
    let usedPercent: Int
    let resetAt: Int
    let rawUsedPercent: Int?
    let rawResetAt: Int?
    let duration: Int?
    let hasDuration: Bool

    init(object: JSONObject) throws {
        guard let usedPercent = WorkspacePayloadSupport.intValue(from: object["used_percent"]),
              let resetAt = WorkspacePayloadSupport.intValue(from: object["reset_at"]) else {
            throw WorkspaceLimitService.unsupportedAuthenticatedResponse()
        }

        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.rawUsedPercent = SelectorIdentityEvidence.integer(object["used_percent"])
        self.rawResetAt = SelectorIdentityEvidence.integer(object["reset_at"])
        self.duration = SelectorIdentityEvidence.integer(object["limit_window_seconds"])
        self.hasDuration = object["limit_window_seconds"] != nil
    }

    func selectorWindow(expectedDuration: Int) -> SelectorQuotaWindow? {
        guard let percent = rawUsedPercent, (0...100).contains(percent),
              let reset = rawResetAt, reset > 0, reset <= 9_007_199_254_740,
              !hasDuration || duration == expectedDuration else { return nil }
        return SelectorQuotaWindow(remainingPercent: 100 - percent, resetAt: Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    func requireWindow() throws -> WorkspaceLimitWindow {
        guard resetAt > 0 else {
            throw ChatGPTAPIError.unsupported("The app found a limit window without a reset time.")
        }

        return WorkspaceLimitWindow(
            usedPercent: max(0, min(usedPercent, 100)),
            resetAt: Date(timeIntervalSince1970: TimeInterval(resetAt))
        )
    }
}
