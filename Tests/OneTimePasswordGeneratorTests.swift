import Foundation
import Testing
@testable import CodexPlusBar

struct OneTimePasswordGeneratorTests {
    @Test
    func totpMatchesRFC6238SHA1Vector() throws {
        let generator = try TOTPGenerator(
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            digits: 8
        )

        #expect(generator.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(generator.code(at: Date(timeIntervalSince1970: 1_111_111_109)) == "07081804")
        #expect(generator.code(at: Date(timeIntervalSince1970: 2_000_000_000)) == "69279037")
    }

    @Test
    func totpAcceptsGroupedLowercaseSecrets() throws {
        let generator = try TOTPGenerator(secret: "gez dgnbv-gy3tqojq gezdgnbvgy3tqojq", digits: 8)

        #expect(generator.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
    }

    @Test
    func totpReadsSecretFromOtpauthURL() throws {
        let generator = try TOTPGenerator(
            secret: "otpauth://totp/CodexPlusBar:alpha@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=CodexPlusBar",
            digits: 8
        )

        #expect(generator.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
    }

    @Test
    func totpUsesDigitsAndPeriodFromOtpauthURLWhenPresent() throws {
        let generator = try TOTPGenerator(
            secret: "otpauth://totp/CodexPlusBar:alpha@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=CodexPlusBar&digits=8&period=30"
        )

        #expect(generator.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
    }

    @Test
    func totpReadsSecretFromTwoFALiveTokenURL() throws {
        let generator = try TOTPGenerator(secret: "https://2fa.live/tok/JBSWY3DP")

        #expect(generator.code(at: Date(timeIntervalSince1970: 59)) == "409098")
    }

    @Test
    func totpAcceptsShortExistingBase32Secrets() throws {
        let generator = try TOTPGenerator(secret: "JBSWY3DP")

        #expect(generator.code(at: Date(timeIntervalSince1970: 59)) == "409098")
    }

    @Test
    func totpRejectsInvalidSecrets() {
        #expect(throws: OneTimePasswordError.invalidSecret) {
            try TOTPGenerator(secret: "NOT_A_BASE32_SECRET")
        }
    }
}
