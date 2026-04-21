import Foundation

struct AccountCatalogService {
    private let transport: HTTPTransport
    private static let traceHint =
        "Rerun with TRACE_PRIVATE_API=1 and refresh once to inspect /backend-api/accounts/check/v4-2023-04-27."

    init(transport: HTTPTransport) {
        self.transport = transport
    }

    @MainActor
    func fetchCatalog() async throws -> [AccountCatalogItem] {
        let response = try await transport.data(for: Self.makeRequest())
        return try Self.decodeCatalog(from: response.data)
    }

    static func makeRequest(now: Date = .now, timeZone: TimeZone = .current) -> URLRequest {
        var components = URLComponents(
            string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27"
        )!
        let offsetMinutes = -(timeZone.secondsFromGMT(for: now) / 60)
        components.queryItems = [
            URLQueryItem(name: "timezone_offset_min", value: String(offsetMinutes))
        ]

        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    static func decodeCatalog(from data: Data) throws -> [AccountCatalogItem] {
        switch WorkspacePayloadSupport.inspectPayload(in: data) {
        case .html, .unauthorizedJSON:
            throw ChatGPTAPIError.unauthorized
        case let .json(payload):
            return try normalizeCatalog(from: payload)
        case .empty:
            throw ChatGPTAPIError.unsupported(
                "ChatGPT returned an empty account response. \(traceHint)"
            )
        case .unrecognized:
            throw ChatGPTAPIError.unsupported(
                "ChatGPT returned an account response the app could not understand. \(traceHint)"
            )
        }
    }

    private static func normalizeCatalog(from payload: Any) throws -> [AccountCatalogItem] {
        let collection = try WorkspacePayloadSupport.extractCollection(from: payload, traceHint: traceHint)
        var items: [AccountCatalogItem] = []
        var encounteredUnrecognizedEntry = false

        for entry in collection.entries {
            switch parseCatalogItem(from: entry) {
            case let .catalogItem(item):
                items.append(item)
            case .unrecognized:
                encounteredUnrecognizedEntry = true
            }
        }

        if items.isEmpty && encounteredUnrecognizedEntry {
            throw ChatGPTAPIError.unsupported(
                "ChatGPT returned an authenticated account response the app could not understand. \(traceHint)"
            )
        }

        let normalizedItems = AccountCatalogNormalizer.normalize(items)

        switch collection.ordering {
        case let .explicit(ids):
            return orderedItems(normalizedItems, orderedBy: ids)
        case .preserveInput:
            return normalizedItems
        case .sortByNameThenID:
            return normalizedItems.sorted(by: itemSort)
        }
    }

    private static func parseCatalogItem(from entry: WorkspaceEntry) -> CatalogParseResult {
        guard let object = entry.payload as? JSONObject else {
            return .unrecognized
        }

        let accountObject = (object["account"] as? JSONObject) ?? object
        guard let accountID = WorkspacePayloadSupport.resolveWorkspaceID(from: entry) else {
            return .unrecognized
        }

        let name = WorkspacePayloadSupport.firstNonEmptyString(
            from: accountObject["name"],
            object["name"],
            accountID
        ) ?? accountID
        let planType = WorkspacePayloadSupport.firstNonEmptyString(
            from: accountObject["plan_type"],
            accountObject["planType"],
            object["plan_type"],
            object["planType"]
        ) ?? "unknown"
        let entitlementObject = (object["entitlement"] as? JSONObject) ?? [:]
        let isUsableInSession = WorkspacePayloadSupport.boolValue(
            from: object["can_access_with_session"] ?? object["canAccessWithSession"]
        ) ?? true

        return .catalogItem(
            AccountCatalogItem(
                accountID: accountID,
                displayName: name,
                planType: planType,
                expiresAt: WorkspacePayloadSupport.dateValue(
                    from: entitlementObject["expires_at"]
                        ?? entitlementObject["expiresAt"]
                        ?? object["expires_at"]
                        ?? object["expiresAt"]
                ),
                renewsAt: WorkspacePayloadSupport.dateValue(
                    from: entitlementObject["renews_at"]
                        ?? entitlementObject["renewsAt"]
                        ?? object["renews_at"]
                        ?? object["renewsAt"]
                ),
                hasActiveSubscription: WorkspacePayloadSupport.boolValue(
                    from: entitlementObject["has_active_subscription"]
                        ?? entitlementObject["hasActiveSubscription"]
                ),
                isDeactivated: WorkspacePayloadSupport.boolValue(
                    from: accountObject["is_deactivated"] ?? accountObject["isDeactivated"]
                ) ?? false,
                isUsableInSession: isUsableInSession
            )
        )
    }

    private static func orderedItems(_ items: [AccountCatalogItem], orderedBy ids: [String]) -> [AccountCatalogItem] {
        var remainingItems = items
        var ordered: [AccountCatalogItem] = []
        var consumedIDs: Set<String> = []

        for id in ids {
            guard consumedIDs.insert(id).inserted else {
                continue
            }
            guard let index = remainingItems.firstIndex(where: { $0.accountID == id }) else {
                continue
            }
            ordered.append(remainingItems.remove(at: index))
        }

        ordered.append(contentsOf: remainingItems.sorted(by: itemSort))
        return ordered
    }

    private static func itemSort(_ lhs: AccountCatalogItem, _ rhs: AccountCatalogItem) -> Bool {
        let lhsName = lhs.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let rhsName = rhs.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if lhsName == rhsName {
            return lhs.accountID.localizedStandardCompare(rhs.accountID) == .orderedAscending
        }

        return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
    }
}

private enum CatalogParseResult {
    case catalogItem(AccountCatalogItem)
    case unrecognized
}
