import Foundation
import Testing
@testable import CodexPlusBar

struct CloudSyncAvailabilityTests {
    @Test func realEngineStartWithUnavailableSigningCannotReachInjectedFactory() async {
        let driver = CloudKitEngineDriver(availability: .init { nil }, makeContainer: { _ in
            Issue.record("Driver called CKContainer factory before checking availability")
            throw CloudJournalError.invalidTransition
        })
        await #expect(throws: CloudSyncAvailabilityError.unavailable) {
            try await driver.start(owner: .init(container: "iCloud.com.linda.CodexPlusBar", environment: .production, userRecordName: "synthetic"),
                                   state: nil, callbacks: .init(event: { _ in }, nextBatch: { _, _ in nil }))
        }
    }

    @Test func unavailableSigningNeverCallsContainerFactory() throws {
        for entitlements in [nil, Self.valid(adHoc: true), Self.valid(services: []), Self.valid(containers: []),
                             Self.valid(push: "development"), Self.valid(groups: [])] {
            let availability = CloudSyncAvailability { entitlements }
            #expect(throws: CloudSyncAvailabilityError.unavailable) {
                try availability.withContainer { _ -> String in
                    Issue.record("Unavailable signing reached a container factory")
                    return "unexpected"
                }
            }
        }
    }

    @Test func entitledFactoryReceivesOnlyApprovedContainerAndExactEnvironment() throws {
        let availability = CloudSyncAvailability { Self.valid() }
        #expect(availability.environment == .production)
        let container = try availability.withContainer(environment: .production) { $0 }
        #expect(container == "iCloud.com.linda.CodexPlusBar")
        #expect(throws: CloudSyncAvailabilityError.unavailable) {
            try availability.withContainer(environment: .development) { _ in Issue.record("Wrong environment reached factory") }
        }
    }

    @Test func missingTeamOrApplicationIdentityFailsClosed() throws {
        var signed = Self.valid()
        signed.teamIdentifier = "another-team"
        let wrongTeam = signed
        #expect(CloudSyncAvailability { wrongTeam }.environment == nil)
        signed = Self.valid()
        signed.applicationIdentifier = "2Z8N5KTWQZ.another-app"
        let wrongApplication = signed
        #expect(CloudSyncAvailability { wrongApplication }.environment == nil)
    }

    private static func valid(adHoc: Bool = false, services: [String] = ["CloudKit"],
                              containers: [String] = ["iCloud.com.linda.CodexPlusBar"],
                              push: String = "production",
                              groups: [String] = ["2Z8N5KTWQZ.com.linda.CodexPlusBar"]) -> CloudSignedEntitlements {
        .init(isAdHoc: adHoc, containers: containers, services: services, environment: "Production", pushEnvironment: push,
              teamIdentifier: "2Z8N5KTWQZ", applicationIdentifier: "2Z8N5KTWQZ.com.linda.CodexPlusBar", keychainGroups: groups)
    }
}
