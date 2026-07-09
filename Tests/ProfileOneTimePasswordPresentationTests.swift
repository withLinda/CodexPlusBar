import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileOneTimePasswordPresentationTests {
    @Test
    func validSecretDefaultsToHiddenSafeState() {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            isCopied: false,
            referenceDate: Date(timeIntervalSince1970: 59)
        )

        #expect(presentation.isVisible)
        #expect(presentation.titleText == "Current OTP")
        #expect(presentation.codeText == "")
        #expect(presentation.isCodeMasked)
        #expect(presentation.statusText == "2FA key saved")
        #expect(presentation.copyText == "")
        #expect(presentation.copyTitle == "Show OTP")
        #expect(presentation.copySymbolName == "eye")
        #expect(presentation.isCopyDisabled == false)
        #expect(presentation.accessibilityValue == "OTP covered. 2FA key saved.")
        #expect([presentation.titleText, presentation.codeText, presentation.statusText].contains { $0.localizedCaseInsensitiveContains("hidden") } == false)
    }

    @Test
    func revealedValidSecretShowsGeneratedCodeAndCopyAction() {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            isRevealed: true,
            isCopied: false,
            referenceDate: Date(timeIntervalSince1970: 59)
        )

        #expect(presentation.isVisible)
        #expect(presentation.codeText == "287082")
        #expect(presentation.isCodeMasked == false)
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
            isRevealed: true,
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
            isRevealed: true,
            isCopied: false,
            referenceDate: Date(timeIntervalSince1970: 59)
        )

        #expect(presentation.isVisible)
        #expect(presentation.codeText == "------")
        #expect(presentation.isCodeMasked == false)
        #expect(presentation.statusText == "Check 2FA key")
        #expect(presentation.isCopyDisabled)
        #expect(presentation.accessibilityValue == "2FA key is not valid.")
    }

    @Test
    func hiddenStateDoesNotValidateSecretBeforeUserRequestsOTP() {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: "not_valid",
            isCopied: false,
            referenceDate: Date(timeIntervalSince1970: 59)
        )

        #expect(presentation.isVisible)
        #expect(presentation.titleText == "Current OTP")
        #expect(presentation.codeText == "")
        #expect(presentation.isCodeMasked)
        #expect(presentation.statusText == "2FA key saved")
        #expect(presentation.copyTitle == "Show OTP")
        #expect(presentation.isCopyDisabled == false)
    }
}
