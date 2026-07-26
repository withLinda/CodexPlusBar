import Foundation

struct ClaudeUsageService {
    static func makeUsageRequest(organizationID: String) throws -> URLRequest {
        guard let normalizedOrganizationID = ClaudeBootstrapService.normalizedOrganizationID(
            organizationID
        ) else {
            throw invalidOrganizationError()
        }

        let url = ClaudeWebURLs.organizationsEndpoint
            .appendingPathComponent(normalizedOrganizationID)
            .appendingPathComponent("usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    static func decodeSnapshot(
        from data: Data,
        organizationID: String,
        fetchedAt: Date = .now
    ) throws -> WorkspaceLimitSnapshot {
        guard let normalizedOrganizationID = ClaudeBootstrapService.normalizedOrganizationID(
            organizationID
        ) else {
            throw invalidOrganizationError()
        }

        switch WorkspacePayloadSupport.inspectPayload(in: data) {
        case .html, .unauthorizedJSON:
            throw ChatGPTAPIError.unauthorized
        case .empty:
            throw ChatGPTAPIError.unsupported(
                "Claude returned no usage data for this profile."
            )
        case .unrecognized:
            throw unsupportedResponse()
        case .json:
            break
        }

        let payload: UsagePayload
        do {
            payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        } catch {
            throw unsupportedResponse()
        }

        let activeLimits = payload.limits.filter { $0.isActive != false }
        let primaryLimit = activeLimits.first(where: { $0.matchesPrimaryWindow })
        let secondaryLimit = activeLimits.first(where: { $0.matchesSecondaryWindow })
        let primaryWindow = window(from: primaryLimit) ?? window(from: payload.fiveHour)
        let secondaryWindow = window(from: secondaryLimit) ?? window(from: payload.sevenDay)

        guard let primaryWindow else {
            throw unsupportedResponse()
        }

        return WorkspaceLimitSnapshot(
            workspaceID: normalizedOrganizationID,
            accountID: normalizedOrganizationID,
            planType: "claude",
            primaryWindow: primaryWindow,
            secondaryWindow: secondaryWindow,
            fetchedAt: fetchedAt
        )
    }

    private static func window(from limit: LimitPayload?) -> WorkspaceLimitWindow? {
        guard let limit,
              let percent = limit.percent,
              let resetAt = WorkspacePayloadSupport.dateValue(from: limit.resetsAt) else {
            return nil
        }

        return WorkspaceLimitWindow(
            usedPercent: normalizedPercent(percent),
            resetAt: resetAt
        )
    }

    private static func window(from window: WindowPayload?) -> WorkspaceLimitWindow? {
        guard let window,
              let utilization = window.utilization,
              let resetAt = WorkspacePayloadSupport.dateValue(from: window.resetsAt) else {
            return nil
        }

        return WorkspaceLimitWindow(
            usedPercent: normalizedPercent(utilization),
            resetAt: resetAt
        )
    }

    private static func normalizedPercent(_ percent: Double) -> Int {
        Int(min(100, max(0, percent)).rounded())
    }

    private static func unsupportedResponse() -> ChatGPTAPIError {
        ChatGPTAPIError.unsupported(
            "Claude returned usage data, but the format changed and the app could not read it."
        )
    }

    private static func invalidOrganizationError() -> ChatGPTAPIError {
        ChatGPTAPIError.unsupported(
            "Claude returned an invalid organization identifier."
        )
    }
}

private struct UsagePayload: Decodable {
    let fiveHour: WindowPayload?
    let sevenDay: WindowPayload?
    let limits: [LimitPayload]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(WindowPayload.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(WindowPayload.self, forKey: .sevenDay)
        limits = try container.decodeIfPresent([LimitPayload].self, forKey: .limits) ?? []
    }
}

private struct WindowPayload: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct LimitPayload: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    var matchesPrimaryWindow: Bool {
        normalizedIdentity.contains("session")
            || normalizedIdentity.contains("five_hour")
            || normalizedIdentity.contains("5h")
    }

    var matchesSecondaryWindow: Bool {
        normalizedIdentity.contains("seven_day")
            || normalizedIdentity.contains("weekly")
            || normalizedIdentity.contains("week")
    }

    private var normalizedIdentity: String {
        [kind, group]
            .compactMap { $0?.lowercased() }
            .joined(separator: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
