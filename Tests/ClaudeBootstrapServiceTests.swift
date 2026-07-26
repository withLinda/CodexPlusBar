import Foundation
import Testing
@testable import CodexPlusBar

extension Tag {
    @Tag static var networking: Self
}

struct ClaudeBootstrapServiceTests {
    private let firstOrganizationID = "11111111-2222-4333-8444-555555555555"
    private let secondOrganizationID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @Test(.tags(.networking))
    func requestUsesCurrentClaudeEdgeBootstrapEndpoint() {
        let request = ClaudeBootstrapService.makeRequest()

        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://claude.ai/edge-api/bootstrap"
                    + "?statsig_hashing_algorithm=djb2"
                    + "&growthbook_format=sdk"
                    + "&include_system_prompts=false"
        )
    }

    @Test(.tags(.networking))
    func nestedOrganizationUUIDIsDecodedWithoutUsingNumericID() throws {
        let organizationIDs = try ClaudeBootstrapService.decodeOrganizationIDs(
            from: Data(
                """
                {
                  "account": {
                    "memberships": [
                      {
                        "role": "admin",
                        "seat_tier": "pro",
                        "organization": {
                          "id": 123456,
                          "uuid": "\(firstOrganizationID)",
                          "capabilities": ["chat"]
                        }
                      }
                    ]
                  },
                  "growthbook": {
                    "features": {}
                  }
                }
                """.utf8
            )
        )

        #expect(organizationIDs == [firstOrganizationID])
    }

    @Test(.tags(.networking))
    func lastActiveOrganizationIsTriedFirstForMultipleMemberships() throws {
        let organizationIDs = try ClaudeBootstrapService.decodeOrganizationIDs(
            from: bootstrapData(
                organizationIDs: [firstOrganizationID, secondOrganizationID]
            ),
            preferredOrganizationID: secondOrganizationID.uppercased()
        )

        #expect(organizationIDs == [secondOrganizationID, firstOrganizationID])
    }

    @Test(.tags(.networking))
    func duplicateAndInvalidOrganizationIDsAreRemoved() throws {
        let organizationIDs = try ClaudeBootstrapService.decodeOrganizationIDs(
            from: Data(
                """
                {
                  "account": {
                    "memberships": [
                      {"organization": {"uuid": "\(firstOrganizationID)"}},
                      {"organization": {"uuid": "not-a-uuid"}},
                      {"organization_uuid": "\(firstOrganizationID.uppercased())"}
                    ]
                  }
                }
                """.utf8
            )
        )

        #expect(organizationIDs == [firstOrganizationID])
    }

    @Test(.tags(.networking))
    func directOrganizationUUIDIsUsedWhenNestedValueIsInvalid() throws {
        let organizationIDs = try ClaudeBootstrapService.decodeOrganizationIDs(
            from: Data(
                """
                {
                  "account": {
                    "memberships": [
                      {
                        "organization": {"uuid": "not-a-uuid"},
                        "organization_uuid": "\(secondOrganizationID)"
                      }
                    ]
                  }
                }
                """.utf8
            )
        )

        #expect(organizationIDs == [secondOrganizationID])
    }

    @Test(.tags(.networking))
    func missingAccountMeansClaudeSessionNeedsLogin() {
        #expect(throws: ChatGPTAPIError.unauthorized) {
            _ = try ClaudeBootstrapService.decodeOrganizationIDs(
                from: Data(#"{"account":null}"#.utf8)
            )
        }
    }

    @Test(.tags(.networking))
    func accountWithoutUsableMembershipIsRejected() {
        #expect(
            throws: ChatGPTAPIError.unsupported(
                "Claude did not provide a usable organization for this profile."
            )
        ) {
            _ = try ClaudeBootstrapService.decodeOrganizationIDs(
                from: Data(#"{"account":{"memberships":[]}}"#.utf8)
            )
        }
    }

    private func bootstrapData(organizationIDs: [String]) -> Data {
        let memberships = organizationIDs
            .map { #"{"organization":{"uuid":"\#($0)"}}"# }
            .joined(separator: ",")

        return Data(
            #"{"account":{"memberships":[\#(memberships)]}}"#.utf8
        )
    }
}
