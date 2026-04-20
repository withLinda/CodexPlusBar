import Foundation
import Testing
@testable import CodexPlusBar

struct PlusProfileModelsTests {
    @Test
    func resolvedEmailLinkURLReturnsExistingSchemeURL() {
        let profile = sampleProfile(emailLink: "mailto:test@example.com")

        #expect(profile.normalizedEmailLink == "mailto:test@example.com")
        #expect(profile.resolvedEmailLinkURL?.absoluteString == "mailto:test@example.com")
    }

    @Test
    func resolvedEmailLinkURLAddsHTTPSWhenSchemeIsMissing() {
        let profile = sampleProfile(emailLink: "mail.google.com/mail/u/0/#inbox")

        #expect(profile.normalizedEmailLink == "mail.google.com/mail/u/0/#inbox")
        #expect(profile.resolvedEmailLinkURL?.absoluteString == "https://mail.google.com/mail/u/0/#inbox")
    }

    @Test
    func resolvedEmailLinkURLReturnsNilForBlankOrInvalidInput() {
        #expect(sampleProfile(emailLink: "   ").normalizedEmailLink == nil)
        #expect(sampleProfile(emailLink: "   ").resolvedEmailLinkURL == nil)
        #expect(sampleProfile(emailLink: "https:///").resolvedEmailLinkURL == nil)
    }
}

private func sampleProfile(emailLink: String?) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: "alpha@example.com",
        emailLink: emailLink,
        detectedNote: nil,
        webDataStoreID: UUID(),
        sortOrder: 0,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}
