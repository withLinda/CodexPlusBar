import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileOneTimePasswordPresentationTests {
    @Test
    func validSecretShowsGeneratedCodeAndCopyAction() {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            isCopied: false,
            referenceDate: Date(timeIntervalSince1970: 59)
        )

        #expect(presentation.isVisible)
        #expect(presentation.codeText == "287082")
        #expect(presentation.statusText == "Expires in 1s")
        #expect(presentation.copyText == "287082")
        #expect(presentation.copyTitle == "Copy code")
        #expect(presentation.copySymbolName == "doc.on.doc")
        #expect(presentation.isCopyDisabled == false)
        #expect(presentation.accessibilityValue == "Current OTP 287082, expires in 1 second.")
    }

    @Test
    func copiedStateUsesStableConfirmationText() {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            isCopied: true,
            referenceDate: Date(timeIntervalSince1970: 45)
        )

        #expect(presentation.copyTitle == "Copied")
        #expect(presentation.copySymbolName == "checkmark")
        #expect(presentation.isCopyDisabled == false)
    }

    @Test
    func emptySecretHidesGeneratedCodePanel() {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: "   ",
            isCopied: false,
            referenceDate: Date(timeIntervalSince1970: 59)
        )

        #expect(presentation.isVisible == false)
        #expect(presentation.isCopyDisabled)
        #expect(presentation.codeText == "")
    }

    @Test
    func invalidSecretShowsSmallRepairStateWithoutCopyAction() {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: "not_valid",
            isCopied: false,
            referenceDate: Date(timeIntervalSince1970: 59)
        )

        #expect(presentation.isVisible)
        #expect(presentation.codeText == "------")
        #expect(presentation.statusText == "Check 2FA key")
        #expect(presentation.isCopyDisabled)
        #expect(presentation.accessibilityValue == "2FA key is not valid.")
    }
}
