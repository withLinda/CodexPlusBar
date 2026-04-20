import Foundation
import Testing
@testable import CodexPlusBar

struct CodexThemeTests {
    @Test
    func themeUsesUpdatedEverforestCorePalette() {
        #expect(CodexTheme.Palette.bg0.hex == "#1E2326")
        #expect(CodexTheme.Palette.fg.hex == "#D3C6AA")
        #expect(CodexTheme.Palette.accOrange.hex == "#E69875")
        #expect(CodexTheme.Palette.accRed.hex == "#E67E80")
        #expect(CodexTheme.Palette.accYellow.hex == "#DBBC7F")
    }

    @Test
    func primaryActionGradientStaysOrangeToSalmon() {
        #expect(CodexTheme.primaryActionTokens.count == 2)
        #expect(CodexTheme.primaryActionTokens[0] == CodexTheme.Palette.accOrange)
        #expect(CodexTheme.primaryActionTokens[1] == CodexTheme.Palette.accRed)
    }

    @Test
    func authStateToneMappingMatchesMenuBarStates() {
        #expect(CodexTheme.statusTone(for: .signedIn) == .success)
        #expect(CodexTheme.statusTone(for: .signedIn, limitReached: true) == .warning)
        #expect(CodexTheme.statusTone(for: .signingIn) == .info)
        #expect(CodexTheme.statusTone(for: .signedOut) == .warning)
        #expect(CodexTheme.statusTone(for: .expired) == .warning)
        #expect(CodexTheme.statusTone(for: .unsupported) == .critical)
    }

    @Test
    func progressPaletteGetsWarmerAsRemainingDrops() {
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 90).hex == CodexTheme.Palette.accGreen.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 70).hex == CodexTheme.Palette.accYellow.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 40).hex == CodexTheme.Palette.accOrange.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 10).hex == CodexTheme.Palette.accRed.hex)
    }

    @Test
    func progressPaletteUsesExactBoundaryThresholds() {
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 24).hex == CodexTheme.Palette.accRed.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 25).hex == CodexTheme.Palette.accOrange.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 49).hex == CodexTheme.Palette.accOrange.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 50).hex == CodexTheme.Palette.accYellow.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 74).hex == CodexTheme.Palette.accYellow.hex)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 75).hex == CodexTheme.Palette.accGreen.hex)
    }

    @Test
    func expiryPaletteUsesGoldOrangeAndRedThresholds() {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let calm = CodexTheme.expiryEmphasisToken(
            for: referenceDate.addingTimeInterval(TimeInterval(9 * 24 * 3_600)),
            referenceDate: referenceDate
        )
        let warning = CodexTheme.expiryEmphasisToken(
            for: referenceDate.addingTimeInterval(TimeInterval(5 * 24 * 3_600)),
            referenceDate: referenceDate
        )
        let critical = CodexTheme.expiryEmphasisToken(
            for: referenceDate.addingTimeInterval(TimeInterval(2 * 24 * 3_600)),
            referenceDate: referenceDate
        )
        let expired = CodexTheme.expiryEmphasisToken(
            for: referenceDate.addingTimeInterval(-60),
            referenceDate: referenceDate
        )

        #expect(calm?.hex == CodexTheme.Palette.accYellow.hex)
        #expect(warning?.hex == CodexTheme.Palette.accOrange.hex)
        #expect(critical?.hex == CodexTheme.Palette.accRed.hex)
        #expect(expired?.hex == CodexTheme.Palette.accRed.hex)
        #expect(CodexTheme.expiryEmphasisToken(for: nil, referenceDate: referenceDate) == nil)
    }

    @Test
    func resetPaletteStaysWarmForHighlightedResetValues() {
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: nil).hex == CodexTheme.Palette.accYellow.hex)
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 82).hex == CodexTheme.Palette.accYellow.hex)
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 44).hex == CodexTheme.Palette.accOrange.hex)
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 12).hex == CodexTheme.Palette.accRed.hex)
    }

    @Test
    func resetCountdownPaletteAlwaysUsesAqua() {
        #expect(CodexTheme.resetCountdownEmphasisToken().hex == CodexTheme.Palette.accAqua.hex)
    }
}
