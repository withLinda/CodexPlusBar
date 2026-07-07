import Foundation
import Testing
@testable import CodexPlusBar

struct CodexThemeTests {
    private let darkHardPreset = CodexThemePreset(variant: .dark, contrast: .hard)
    private let lightHardPreset = CodexThemePreset(variant: .light, contrast: .hard)

    @Test
    func themeUsesUpdatedEverforestCorePalette() {
        #expect(CodexTheme.Palette.bg0.hex == "#1E2326")
        #expect(CodexTheme.Palette.fg.hex == "#D3C6AA")
        #expect(CodexTheme.Palette.accOrange.hex == "#E69875")
        #expect(CodexTheme.Palette.accRed.hex == "#E67E80")
        #expect(CodexTheme.Palette.accYellow.hex == "#DBBC7F")
    }

    @Test
    func themeExposesAllEverforestAppearanceAndContrastPresets() {
        let presetIDs = Set(CodexThemePreset.allCases.map(\.id))

        #expect(presetIDs == Set([
            "dark-hard",
            "dark-medium",
            "dark-soft",
            "light-hard",
            "light-medium",
            "light-soft",
        ]))
        #expect(CodexTheme.palette(for: darkHardPreset).bgDim.hex == "#1E2326")
        #expect(CodexTheme.palette(for: CodexThemePreset(variant: .dark, contrast: .medium)).bgDim.hex == "#232A2E")
        #expect(CodexTheme.palette(for: CodexThemePreset(variant: .dark, contrast: .soft)).bgDim.hex == "#293136")
        #expect(CodexTheme.palette(for: lightHardPreset).bg0.hex == "#FFFBEF")
        #expect(CodexTheme.palette(for: CodexThemePreset(variant: .light, contrast: .medium)).bg0.hex == "#FDF6E3")
        #expect(CodexTheme.palette(for: CodexThemePreset(variant: .light, contrast: .soft)).bg0.hex == "#F3EAD3")
    }

    @Test
    func themeSettingsDefaultToDarkHardAndIgnoreUnknownValues() throws {
        let suiteName = "CodexThemeTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        #expect(CodexThemeSettings.appearanceMode(in: userDefaults) == .dark)
        #expect(CodexThemeSettings.contrast(in: userDefaults) == .hard)

        userDefaults.set("sepia", forKey: CodexThemeSettings.Keys.appearanceMode)
        userDefaults.set("paper", forKey: CodexThemeSettings.Keys.contrast)

        #expect(CodexThemeSettings.appearanceMode(in: userDefaults) == .dark)
        #expect(CodexThemeSettings.contrast(in: userDefaults) == .hard)
    }

    @Test
    func themeUsesHardEverforestSurfaceHierarchy() {
        #expect(CodexTheme.canvasFillToken(for: darkHardPreset).hex == "#1E2326")
        #expect(CodexTheme.shellFillToken(for: darkHardPreset).hex == "#272E33")
        #expect(CodexTheme.surfaceToken(for: .regular, preset: darkHardPreset).hex == "#2E383C")
        #expect(CodexTheme.surfaceToken(for: .nested, preset: darkHardPreset).hex == "#374145")
        #expect(CodexTheme.surfaceToken(for: .strong, preset: darkHardPreset).hex == "#374145")
        #expect(CodexTheme.surfaceToken(for: .subtle, preset: darkHardPreset).hex != "#272E33")
    }

    @Test
    func themeRefreshContextChangesTokensWithoutResettingViewIdentity() {
        let hardContext = CodexThemeRefreshContext(appearanceMode: .dark, contrast: .hard)
        let mediumContext = CodexThemeRefreshContext(appearanceMode: .dark, contrast: .medium)

        #expect(hardContext.preset == darkHardPreset)
        #expect(mediumContext.preset == CodexThemePreset(variant: .dark, contrast: .medium))
        #expect(hardContext.preferredColorScheme == .dark)
        #expect(mediumContext.preferredColorScheme == .dark)
        #expect(hardContext.identityResetKey == nil)
        #expect(mediumContext.identityResetKey == nil)
    }

    @Test
    func usefulTextRolesPassWCAGContrastOnMainSurfacesForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)
            let textRoles: [(name: String, token: CodexColorToken)] = [
                ("primary", palette.primaryText),
                ("muted", palette.mutedText),
                ("support", palette.supportText),
            ]

            for textRole in textRoles {
                for surface in mainSurfaceTokens(for: preset) {
                    #expect(
                        contrastRatio(textRole.token, surface.token) >= 4.5,
                        "\(preset.id) \(textRole.name) on \(surface.name) should pass WCAG normal text contrast"
                    )
                }
            }
        }
    }

    @Test
    func surfaceTokensKeepPerceptualDeltaLStarSeparationForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let pairs: [(name: String, front: CodexColorToken, back: CodexColorToken, minimumDelta: Double)] = [
                (
                    "shell-canvas",
                    CodexTheme.shellFillToken(for: preset),
                    CodexTheme.canvasFillToken(for: preset),
                    4.0
                ),
                (
                    "regular-shell",
                    CodexTheme.surfaceToken(for: .regular, preset: preset),
                    CodexTheme.shellFillToken(for: preset),
                    preset.variant == .dark ? 3.5 : 1.6
                ),
                (
                    "nested-regular",
                    CodexTheme.surfaceToken(for: .nested, preset: preset),
                    CodexTheme.surfaceToken(for: .regular, preset: preset),
                    preset.variant == .dark ? 3.5 : 1.6
                ),
                (
                    "strong-shell",
                    CodexTheme.surfaceToken(for: .strong, preset: preset),
                    CodexTheme.shellFillToken(for: preset),
                    5.0
                ),
            ]

            for pair in pairs {
                #expect(
                    deltaLStar(pair.front, pair.back) >= pair.minimumDelta,
                    "\(preset.id) \(pair.name) should keep perceptual layer separation"
                )
            }
        }
    }

    @Test
    func darkHardSurfaceSheenStaysMatteEnoughForCompactPanels() {
        let strongSheen = CodexTheme.surfaceSheenOpacity(for: .strong, preset: darkHardPreset)
        let regularSheen = CodexTheme.surfaceSheenOpacity(for: .regular, preset: darkHardPreset)
        let nestedSheen = CodexTheme.surfaceSheenOpacity(for: .nested, preset: darkHardPreset)

        #expect(strongSheen.top <= 0.024)
        #expect(strongSheen.middle <= 0.008)
        #expect(regularSheen.top <= 0.018)
        #expect(regularSheen.middle <= 0.006)
        #expect(nestedSheen.top <= 0.014)
        #expect(nestedSheen.middle <= 0.004)
    }

    @Test
    func lightPresetKeepsDenseMetricTextReadableInsteadOfAccentColored() {
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 90, preset: lightHardPreset).hex == "#1E2326")
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 12, preset: lightHardPreset).hex == "#1E2326")
        #expect(CodexTheme.resetCountdownEmphasisToken(preset: lightHardPreset).hex == "#1E2326")
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

private func mainSurfaceTokens(for preset: CodexThemePreset) -> [(name: String, token: CodexColorToken)] {
    [
        ("canvas", CodexTheme.canvasFillToken(for: preset)),
        ("shell", CodexTheme.shellFillToken(for: preset)),
        ("regular", CodexTheme.surfaceToken(for: .regular, preset: preset)),
        ("nested", CodexTheme.surfaceToken(for: .nested, preset: preset)),
        ("strong", CodexTheme.surfaceToken(for: .strong, preset: preset)),
        ("subtle", CodexTheme.surfaceToken(for: .subtle, preset: preset)),
    ]
}

private func contrastRatio(_ foreground: CodexColorToken, _ background: CodexColorToken) -> Double {
    let foregroundLuminance = relativeLuminance(foreground)
    let backgroundLuminance = relativeLuminance(background)
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func deltaLStar(_ lhs: CodexColorToken, _ rhs: CodexColorToken) -> Double {
    abs(perceptualLightness(lhs) - perceptualLightness(rhs))
}

private func perceptualLightness(_ token: CodexColorToken) -> Double {
    let y = relativeLuminance(token)
    let epsilon = 216.0 / 24_389.0
    let kappa = 24_389.0 / 27.0
    let value = y > epsilon
        ? pow(y, 1.0 / 3.0)
        : ((kappa * y) + 16.0) / 116.0
    return (116.0 * value) - 16.0
}

private func relativeLuminance(_ token: CodexColorToken) -> Double {
    let rgb = rgbComponents(token)
    return (0.2126 * linearSRGB(rgb.red))
        + (0.7152 * linearSRGB(rgb.green))
        + (0.0722 * linearSRGB(rgb.blue))
}

private func linearSRGB(_ component: Double) -> Double {
    component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
}

private func rgbComponents(_ token: CodexColorToken) -> (red: Double, green: Double, blue: Double) {
    let hex = token.hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let value = Int(hex, radix: 16) ?? 0
    return (
        Double((value >> 16) & 0xFF) / 255.0,
        Double((value >> 8) & 0xFF) / 255.0,
        Double(value & 0xFF) / 255.0
    )
}
