import Foundation

struct ClaudeBootstrapService {
    static let lastActiveOrganizationCookieName = "lastActiveOrg"

    private let transport: HTTPTransport

    init(transport: HTTPTransport) {
        self.transport = transport
    }

    @MainActor
    func fetchOrganizationIDs(
        preferredOrganizationID: String?
    ) async throws -> [String] {
        let response = try await transport.data(for: Self.makeRequest())
        return try Self.decodeOrganizationIDs(
            from: response.data,
            preferredOrganizationID: preferredOrganizationID
        )
    }

    static func makeRequest() -> URLRequest {
        var request = URLRequest(url: ClaudeWebURLs.bootstrapEndpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    static func decodeOrganizationIDs(
        from data: Data,
        preferredOrganizationID: String? = nil
    ) throws -> [String] {
        switch WorkspacePayloadSupport.inspectPayload(in: data) {
        case .html, .unauthorizedJSON:
            throw ChatGPTAPIError.unauthorized
        case .empty:
            throw unsupportedOrganizationResponse()
        case .unrecognized:
            throw changedBootstrapResponse()
        case .json:
            break
        }

        let payload: BootstrapPayload
        do {
            payload = try JSONDecoder().decode(BootstrapPayload.self, from: data)
        } catch {
            throw changedBootstrapResponse()
        }

        guard let account = payload.account else {
            throw ChatGPTAPIError.unauthorized
        }

        var organizationIDs: [String] = []
        var seenOrganizationIDs: Set<String> = []

        for membership in account.memberships ?? [] {
            let organizationID = normalizedOrganizationID(membership.organization?.uuid)
                ?? normalizedOrganizationID(membership.organizationUUID)

            guard let organizationID,
                seenOrganizationIDs.insert(organizationID).inserted
            else {
                continue
            }

            organizationIDs.append(organizationID)
        }

        guard organizationIDs.isEmpty == false else {
            throw unsupportedOrganizationResponse()
        }

        guard let preferredOrganizationID = normalizedOrganizationID(preferredOrganizationID),
              let preferredIndex = organizationIDs.firstIndex(of: preferredOrganizationID),
              preferredIndex != organizationIDs.startIndex
        else {
            return organizationIDs
        }

        organizationIDs.remove(at: preferredIndex)
        organizationIDs.insert(preferredOrganizationID, at: organizationIDs.startIndex)
        return organizationIDs
    }

    static func normalizedOrganizationID(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let decodedValue = value.removingPercentEncoding ?? value
        let trimmingCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\"")
        )
        let trimmedValue = decodedValue.trimmingCharacters(in: trimmingCharacters)

        guard let uuid = UUID(uuidString: trimmedValue) else {
            return nil
        }

        return uuid.uuidString.lowercased()
    }

    private static func changedBootstrapResponse() -> ChatGPTAPIError {
        ChatGPTAPIError.unsupported(
            "Claude returned account data, but the format changed and the app could not read it."
        )
    }

    private static func unsupportedOrganizationResponse() -> ChatGPTAPIError {
        ChatGPTAPIError.unsupported(
            "Claude did not provide a usable organization for this profile."
        )
    }
}

private struct BootstrapPayload: Decodable {
    let account: BootstrapAccount?
}

private struct BootstrapAccount: Decodable {
    let memberships: [BootstrapMembership]?
}

private struct BootstrapMembership: Decodable {
    let organization: BootstrapOrganization?
    let organizationUUID: String?

    enum CodingKeys: String, CodingKey {
        case organization
        case organizationUUID = "organization_uuid"
    }
}

private struct BootstrapOrganization: Decodable {
    let uuid: String?
}
