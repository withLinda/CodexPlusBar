import Foundation

struct WorkspaceLimitService {
    fileprivate static let traceHint =
        "Rerun with TRACE_PRIVATE_API=1 and refresh once to inspect /backend-api/wham/usage."

    static func decodeSnapshot(from data: Data, workspaceID: String) throws -> WorkspaceLimitSnapshot {
        switch WorkspacePayloadSupport.inspectPayload(in: data) {
        case .html, .unauthorizedJSON:
            throw ChatGPTAPIError.unauthorized
        case let .json(payload):
            return try normalizeSnapshot(from: payload, rawData: data, workspaceID: workspaceID)
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

    private static func normalizeSnapshot(from payload: Any, rawData: Data, workspaceID: String) throws -> WorkspaceLimitSnapshot {
        if let rootObject = payload as? JSONObject, rootObject["rate_limit"] != nil {
            if let legacyPayload = try? JSONDecoder.chatGPTAPI.decode(AccountCheckResponse.self, from: rawData) {
                return try snapshot(from: legacyPayload, workspaceID: workspaceID)
            }

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

    private static func snapshot(from payload: AccountCheckResponse, workspaceID: String) throws -> WorkspaceLimitSnapshot {
        WorkspaceLimitSnapshot(
            workspaceID: workspaceID,
            accountID: payload.accountID,
            planType: payload.planType,
            primaryWindow: try payload.rateLimit.primaryWindow.requireWindow(),
            secondaryWindow: try payload.rateLimit.secondaryWindow?.requireWindow(),
            fetchedAt: .now
        )
    }

    private static func snapshot(from entry: WorkspaceEntry, workspaceID: String) throws -> WorkspaceLimitSnapshot {
        guard let object = entry.payload as? JSONObject else {
            throw unsupportedAuthenticatedResponse()
        }

        let accountID = WorkspacePayloadSupport.resolveWorkspaceID(from: entry) ?? workspaceID
        return try snapshot(from: object, workspaceID: workspaceID, accountID: accountID)
    }

    private static func snapshot(from object: JSONObject, workspaceID: String, accountID: String) throws -> WorkspaceLimitSnapshot {
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

        return WorkspaceLimitSnapshot(
            workspaceID: workspaceID,
            accountID: accountID,
            planType: planType,
            primaryWindow: try rateLimit.primaryWindow.requireWindow(),
            secondaryWindow: try rateLimit.secondaryWindow?.requireWindow(),
            fetchedAt: .now
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

private struct AccountCheckResponse: Decodable {
    let accountID: String
    let planType: String
    let rateLimit: RateLimitContainer

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

private struct RateLimitContainer: Decodable {
    let primaryWindow: LimitWindowPayload
    let secondaryWindow: LimitWindowPayload?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(object: JSONObject) throws {
        guard let primaryWindowObject = object["primary_window"] as? JSONObject else {
            throw WorkspaceLimitService.unsupportedAuthenticatedResponse()
        }

        primaryWindow = try LimitWindowPayload(object: primaryWindowObject)
        if let secondaryWindowObject = object["secondary_window"] as? JSONObject {
            secondaryWindow = try LimitWindowPayload(object: secondaryWindowObject)
        } else {
            secondaryWindow = nil
        }
    }
}

private struct LimitWindowPayload: Decodable {
    let usedPercent: Int
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }

    init(object: JSONObject) throws {
        guard let usedPercent = WorkspacePayloadSupport.intValue(from: object["used_percent"]),
              let resetAt = WorkspacePayloadSupport.intValue(from: object["reset_at"]) else {
            throw WorkspaceLimitService.unsupportedAuthenticatedResponse()
        }

        self.usedPercent = usedPercent
        self.resetAt = resetAt
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
