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
        #expect(CodexTheme.Palette.accGreen.hex == "#A7C080")
        #expect(CodexTheme.Palette.accAqua.hex == "#83C092")
        #expect(CodexTheme.Palette.accBlue.hex == "#7FBBB3")
        #expect(CodexTheme.Palette.accPurple.hex == "#D699B6")
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
        #expect(CodexTheme.palette(for: darkHardPreset).accGreen.hex == "#A7C080")
        #expect(CodexTheme.palette(for: darkHardPreset).accAqua.hex == "#83C092")
        #expect(CodexTheme.palette(for: darkHardPreset).accBlue.hex == "#7FBBB3")
        #expect(CodexTheme.palette(for: darkHardPreset).accPurple.hex == "#D699B6")
        #expect(CodexTheme.palette(for: lightHardPreset).accGreen.hex == "#8DA101")
        #expect(CodexTheme.palette(for: lightHardPreset).accAqua.hex == "#35A77C")
        #expect(CodexTheme.palette(for: lightHardPreset).accBlue.hex == "#3A94C5")
        #expect(CodexTheme.palette(for: lightHardPreset).accPurple.hex == "#DF69BA")
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
    func cardFillTokensUseEverforestBg0ForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)

            for cardTier in cardSurfaceTiers {
                #expect(
                    CodexTheme.cardFillToken(for: cardTier.tier, preset: preset).hex == palette.bg0.hex,
                    "\(preset.id) \(cardTier.name) cards should use the preset bg0 token"
                )
            }
        }
    }

    @Test
    func cardTextRolesPassWCAGOnBg0CardsForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)
            let textRoles: [(name: String, token: CodexColorToken)] = [
                ("primary", palette.primaryText),
                ("support", palette.supportText),
                ("dataLabel", palette.dataLabelText),
                ("dataValue", palette.dataValueText),
                ("action", CodexTheme.actionTextToken(preset: preset)),
                ("danger", CodexTheme.dangerTextToken(preset: preset)),
            ]

            for cardTier in cardSurfaceTiers {
                let cardFill = CodexTheme.cardFillToken(for: cardTier.tier, preset: preset)

                for textRole in textRoles {
                    #expect(
                        contrastRatio(textRole.token, cardFill) >= 4.5,
                        "\(preset.id) \(textRole.name) on \(cardTier.name) card fill should pass WCAG normal text contrast"
                    )
                }
            }
        }
    }

    @Test
    func providerCardRolesPassWCAGAndDeltaLStarForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)
            let textRoles: [(name: String, token: CodexColorToken)] = [
                ("heading", palette.strongText),
                ("primary", palette.primaryText),
                ("support", palette.supportText),
                ("dataValue", palette.dataValueText),
            ]

            let codexFill = CodexTheme.profileCardFillToken(
                for: .codex,
                preset: preset
            )
            let claudeFill = CodexTheme.profileCardFillToken(
                for: .claude,
                preset: preset
            )

            #expect(
                codexFill.hex != claudeFill.hex,
                "\(preset.id) provider cards should not collapse to the same fill"
            )

            for provider in ProfileProvider.allCases {
                for isSelected in [false, true] {
                    let fill = CodexTheme.profileCardFillToken(
                        for: provider,
                        isSelected: isSelected,
                        preset: preset
                    )

                    for textRole in textRoles {
                        #expect(
                            contrastRatio(textRole.token, fill) >= 4.5,
                            "\(preset.id) \(provider.displayName) \(textRole.name) on provider card should pass WCAG"
                        )
                        #expect(
                            deltaLStar(textRole.token, fill) >= 40,
                            "\(preset.id) \(provider.displayName) \(textRole.name) on provider card should keep delta L* >= 40"
                        )
                    }

                    let providerAccent = CodexTheme.profileProviderAccentToken(
                        for: provider,
                        isSelected: isSelected,
                        preset: preset
                    )
                    #expect(
                        contrastRatio(providerAccent, fill) >= 4.5,
                        "\(preset.id) \(provider.displayName) badge text should pass WCAG"
                    )
                    #expect(
                        deltaLStar(providerAccent, fill) >= 40,
                        "\(preset.id) \(provider.displayName) badge text should keep delta L* >= 40"
                    )
                }
            }
        }
    }

    @Test
    func phoneSummaryPageRolesPassWCAGAndDeltaLStarForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)
            let surfaces: [(name: String, token: CodexColorToken)] = [
                ("groupCard", CodexTheme.cardFillToken(for: .regular, preset: preset)),
                ("pressedRow", CodexTheme.surfaceToken(for: .nested, preset: preset)),
            ]
            let textRoles: [(name: String, token: CodexColorToken)] = [
                ("heading", palette.strongText),
                ("profile", palette.primaryText),
                ("support", palette.mutedText),
                ("expiryLabel", palette.dataLabelText),
                ("phoneNumber", palette.dataValueText),
                ("navigation", CodexTheme.utilityActionTextToken(preset: preset)),
            ]
            let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
            let expiryValueRoles: [(name: String, token: CodexColorToken)] = [
                ("expiryCalm", CodexTheme.expiryEmphasisToken(
                    for: referenceDate.addingTimeInterval(TimeInterval(9 * 24 * 3_600)),
                    referenceDate: referenceDate,
                    preset: preset
                )),
                ("expiryWarning", CodexTheme.expiryEmphasisToken(
                    for: referenceDate.addingTimeInterval(TimeInterval(5 * 24 * 3_600)),
                    referenceDate: referenceDate,
                    preset: preset
                )),
                ("expiryCritical", CodexTheme.expiryEmphasisToken(
                    for: referenceDate.addingTimeInterval(TimeInterval(2 * 24 * 3_600)),
                    referenceDate: referenceDate,
                    preset: preset
                )),
            ].compactMap { name, token in
                token.map { (name, $0) }
            }

            for surface in surfaces {
                for textRole in textRoles + expiryValueRoles {
                    #expect(
                        contrastRatio(textRole.token, surface.token) >= 4.5,
                        "\(preset.id) phone-summary \(textRole.name) on \(surface.name) should pass WCAG normal text contrast"
                    )
                    #expect(
                        deltaLStar(textRole.token, surface.token) >= 40,
                        "\(preset.id) phone-summary \(textRole.name) on \(surface.name) should keep enough perceptual lightness separation"
                    )
                }
            }
        }
    }

    @Test
    func themeRefreshContextChangesTokensWithoutResettingViewIdentity() {
        let hardContext = CodexThemeRefreshContext(appearanceMode: .dark, contrast: .hard)
        let mediumContext = CodexThemeRefreshContext(appearanceMode: .dark, contrast: .medium)

        #expect(hardContext.preset == darkHardPreset)
        #expect(mediumContext.preset == CodexThemePreset(variant: .dark, contrast: .medium))
        #expect(hardContext.preferredColorScheme == .dark)
        #expect(mediumContext.preferredColorScheme == .dark)
    }

    @Test
    func usefulTextRolesPassWCAGContrastOnMainSurfacesForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            for textRole in usefulTextRoles(for: preset) {
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
    func readableAccentTextTargetsDensePanelContrastForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            for textRole in densePanelAccentTextRoles(for: preset) {
                for surface in mainSurfaceTokens(for: preset) {
                    #expect(
                        contrastRatio(textRole.token, surface.token) >= 5.0,
                        "\(preset.id) \(textRole.name) on \(surface.name) should target 5:1 for dense compact-panel text"
                    )
                }
            }
        }
    }

    @Test
    func textRolesKeepPerceptualDeltaLStarSeparationOnMainSurfacesForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let textRoles = usefulTextRoles(for: preset) + densePanelAccentTextRoles(for: preset)

            for textRole in textRoles {
                for surface in mainSurfaceTokens(for: preset) {
                    #expect(
                        deltaLStar(textRole.token, surface.token) >= 40.0,
                        "\(preset.id) \(textRole.name) on \(surface.name) should keep enough perceptual lightness separation"
                    )
                }
            }
        }
    }

    @Test
    func profileSearchTokensPassWCAGAndDeltaLStarForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let fieldFill = CodexTheme.searchFieldFillToken(preset: preset)
            let inputText = CodexTheme.searchInputTextToken(preset: preset)
            let promptText = CodexTheme.searchPromptTextToken(preset: preset)
            let searchAction = CodexTheme.searchActionToken(preset: preset)
            let focusBorder = CodexTheme.searchFocusBorderToken(preset: preset)

            for textRole in [inputText, promptText] {
                #expect(
                    contrastRatio(textRole, fieldFill) >= 4.5,
                    "\(preset.id) search text should pass WCAG normal text contrast"
                )
                #expect(
                    deltaLStar(textRole, fieldFill) >= 40,
                    "\(preset.id) search text should keep enough perceptual lightness separation"
                )
            }

            #expect(
                contrastRatio(searchAction, fieldFill) >= 3,
                "\(preset.id) search icon should pass WCAG non-text contrast"
            )
            #expect(
                contrastRatio(focusBorder, fieldFill) >= 3,
                "\(preset.id) search focus border should pass WCAG non-text contrast"
            )
            #expect(
                searchAction != CodexTheme.actionTextToken(preset: preset),
                "\(preset.id) search should keep the blue navigation role separate from orange primary actions"
            )
        }
    }

    @Test
    func profileSortControlPassesWCAGAndDeltaLStarForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let controlFill = CodexTheme.surfaceToken(for: .subtle, preset: preset)
            let label = CodexTheme.palette(for: preset).primaryText
            let sortIcon = CodexTheme.utilityActionTextToken(preset: preset)

            #expect(
                contrastRatio(label, controlFill) >= 4.5,
                "\(preset.id) sort label should pass WCAG normal text contrast"
            )
            #expect(
                deltaLStar(label, controlFill) >= 40,
                "\(preset.id) sort label should keep enough perceptual lightness separation"
            )
            #expect(
                contrastRatio(sortIcon, controlFill) >= 3,
                "\(preset.id) sort icon should pass WCAG non-text contrast"
            )
        }
    }

    @Test
    func dataLabelsAndValuesStaySemanticallySeparatedForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)

            #expect(
                palette.dataLabelText != palette.dataValueText,
                "\(preset.id) data labels and data values should not use the same token"
            )

            #expect(
                deltaLStar(palette.dataLabelText, palette.dataValueText) >= 12,
                "\(preset.id) data label and value should have enough perceptual lightness separation"
            )
        }
    }

    @Test
    func lightThemeKeepsNormalLabelsInTheEverforestFgFamily() {
        for contrast in CodexThemeContrast.allCases {
            let preset = CodexThemePreset(variant: .light, contrast: contrast)
            let palette = CodexTheme.palette(for: preset)

            #expect(
                palette.primaryText != palette.strongText,
                "\(preset.id) normal labels should not use black strong text"
            )
            #expect(
                deltaLStar(palette.primaryText, palette.fg) <= 8,
                "\(preset.id) normal labels should stay visually close to Everforest fg"
            )
            #expect(
                deltaLStar(palette.primaryText, palette.strongText) >= 18,
                "\(preset.id) normal labels should stay perceptually separate from dense values"
            )
            #expect(
                palette.dataLabelText == palette.primaryText,
                "\(preset.id) data labels should stay calm like normal labels"
            )
            #expect(
                palette.dataValueText.hex == palette.strongText.hex,
                "\(preset.id) dense values can use strong text"
            )
        }
    }

    @Test
    func lightThemeAccentTextStaysColorfulButReadable() {
        for contrast in CodexThemeContrast.allCases {
            let preset = CodexThemePreset(variant: .light, contrast: contrast)
            let palette = CodexTheme.palette(for: preset)
            let textRoles: [(name: String, token: CodexColorToken)] = [
                ("action", CodexTheme.actionTextToken(preset: preset)),
                ("success", CodexTheme.readableAccentToken(palette.accAqua, preset: preset)),
                ("info", CodexTheme.readableAccentToken(palette.accBlue, preset: preset)),
                ("fullLimitData", CodexTheme.progressTextToken(forRemainingPercent: 100, preset: preset)),
                ("healthyData", CodexTheme.progressTextToken(forRemainingPercent: 90, preset: preset)),
                ("warningData", CodexTheme.resetEmphasisToken(forRemainingPercent: 82, preset: preset)),
                ("dangerData", CodexTheme.progressTextToken(forRemainingPercent: 12, preset: preset)),
            ]

            for textRole in textRoles {
                #expect(
                    textRole.token != palette.strongText,
                    "\(preset.id) \(textRole.name) should keep a visible Everforest hue"
                )

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
    func statusAndDataAccentsUseSeparateEverforestRoles() {
        let darkPalette = CodexTheme.palette(for: darkHardPreset)

        #expect(CodexTheme.statusAccentToken(for: .success).hex == darkPalette.accAqua.hex)
        #expect(CodexTheme.statusAccentToken(for: .info).hex == darkPalette.accBlue.hex)
        #expect(CodexTheme.fullLimitAccentToken(preset: darkHardPreset).hex == darkPalette.accPurple.hex)
        #expect(CodexTheme.progressAccentToken(forRemainingPercent: 90, preset: darkHardPreset).hex == darkPalette.accGreen.hex)
        #expect(CodexTheme.fullLimitAccentToken(preset: darkHardPreset) != darkPalette.accGreen)
    }

    @Test
    func exactFullLimitUsesDistinctPurpleForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)
            let fullLimitText = CodexTheme.progressTextToken(forRemainingPercent: 100, preset: preset)
            let nearbyHealthyText = CodexTheme.progressTextToken(forRemainingPercent: 99, preset: preset)

            #expect(CodexTheme.fullLimitAccentToken(preset: preset) == palette.accPurple)
            #expect(CodexTheme.progressAccentToken(forRemainingPercent: 100, preset: preset) == palette.accPurple)
            #expect(CodexTheme.progressAccentToken(forRemainingPercent: 99, preset: preset) == palette.accGreen)
            #expect(CodexTheme.progressAccentToken(forRemainingPercent: 101, preset: preset) == palette.accGreen)
            #expect(fullLimitText != nearbyHealthyText)
            #expect(fullLimitText != palette.strongText)
        }
    }

    @Test
    func profileTagAccentsUseRequestedEverforestRoles() {
        let darkPalette = CodexTheme.palette(for: darkHardPreset)

        #expect(CodexTheme.profileTagAccentToken(for: .active, preset: darkHardPreset).hex == darkPalette.accGreen.hex)
        #expect(CodexTheme.profileTagAccentToken(for: .needAction, preset: darkHardPreset).hex == darkPalette.accRed.hex)
        #expect(CodexTheme.profileTagAccentToken(for: .pending, preset: darkHardPreset).hex == darkPalette.accYellow.hex)
        #expect(CodexTheme.profileTagAccentToken(for: .active, preset: darkHardPreset).hex != CodexTheme.profileTagAccentToken(for: .pending, preset: darkHardPreset).hex)
        #expect(CodexTheme.profileTagAccentToken(for: .needAction, preset: darkHardPreset).hex != CodexTheme.profileTagAccentToken(for: .pending, preset: darkHardPreset).hex)
    }

    @Test
    func profileTagTextStaysReadableWhileBordersStaySubtleForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            for tone in CodexProfileTagTone.allCases {
                let text = CodexTheme.profileTagTextToken(for: tone, preset: preset)

                for isSelected in [true, false] {
                    let fill = CodexTheme.profileTagFillToken(for: tone, isSelected: isSelected, preset: preset)
                    let border = CodexTheme.profileTagBorderToken(for: tone, isSelected: isSelected, preset: preset)
                    let textContrast = contrastRatio(text, fill)
                    let borderContrast = contrastRatio(border, fill)

                    #expect(
                        textContrast >= 4.5,
                        "\(preset.id) \(tone.rawValue) tag text should pass WCAG normal text contrast on its own fill"
                    )
                    #expect(
                        deltaLStar(text, fill) >= 40.0,
                        "\(preset.id) \(tone.rawValue) tag text should keep enough perceptual lightness separation on its own fill"
                    )
                    #expect(
                        borderContrast >= (isSelected ? 1.14 : 1.04),
                        "\(preset.id) \(tone.rawValue) tag border should remain visible as a quiet edge"
                    )
                    #expect(
                        borderContrast <= (isSelected ? 2.10 : 1.45),
                        "\(preset.id) \(tone.rawValue) tag border should stay subtler than the readable text"
                    )
                    #expect(
                        borderContrast < textContrast,
                        "\(preset.id) \(tone.rawValue) tag border should not compete with tag text"
                    )
                    #expect(
                        deltaLStar(border, fill) < deltaLStar(text, fill),
                        "\(preset.id) \(tone.rawValue) tag border should use less lightness contrast than tag text"
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
    func lightPresetUsesReadableTintedAccentForDenseMetricText() {
        let palette = CodexTheme.palette(for: lightHardPreset)

        #expect(CodexTheme.progressTextToken(forRemainingPercent: 90, preset: lightHardPreset) != palette.strongText)
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 100, preset: lightHardPreset) != palette.strongText)
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 12, preset: lightHardPreset) != palette.strongText)
        #expect(CodexTheme.resetCountdownEmphasisToken(preset: lightHardPreset) != palette.strongText)
        #expect(
            CodexTheme.progressTextToken(forRemainingPercent: 100, preset: lightHardPreset)
                == CodexTheme.readableAccentToken(palette.accPurple, preset: lightHardPreset)
        )
        #expect(
            CodexTheme.progressTextToken(forRemainingPercent: 90, preset: lightHardPreset)
                == CodexTheme.readableAccentToken(palette.accGreen, preset: lightHardPreset)
        )
        #expect(
            CodexTheme.resetEmphasisToken(forRemainingPercent: 12, preset: lightHardPreset)
                == CodexTheme.readableAccentToken(palette.accRed, preset: lightHardPreset)
        )
        #expect(
            CodexTheme.resetCountdownEmphasisToken(preset: lightHardPreset)
                == CodexTheme.readableAccentToken(palette.accBlue, preset: lightHardPreset)
        )
    }

    @Test
    func oneTimePasswordTextRolesUseCalmValueAndSupportTokensForEveryPreset() {
        for preset in CodexThemePreset.allCases {
            let palette = CodexTheme.palette(for: preset)

            #expect(CodexTheme.oneTimePasswordCodeTextToken(preset: preset) == palette.dataValueText)
            #expect(CodexTheme.oneTimePasswordStatusTextToken(preset: preset) == palette.supportText)
            #expect(CodexTheme.oneTimePasswordMaskFillToken(preset: preset) == palette.supportText)
        }
    }

    @Test
    func primaryActionGradientStaysOrangeToSalmon() {
        #expect(CodexTheme.primaryActionTokens.count == 2)
        #expect(CodexTheme.primaryActionTokens[0] == CodexTheme.Palette.accOrange)
        #expect(CodexTheme.primaryActionTokens[1] == CodexTheme.Palette.accRed)
    }

    @Test
    func progressPaletteGetsWarmerAsRemainingDrops() {
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 100) == CodexTheme.readableAccentToken(CodexTheme.Palette.accPurple))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 90) == CodexTheme.readableAccentToken(CodexTheme.Palette.accGreen))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 70) == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 40) == CodexTheme.readableAccentToken(CodexTheme.Palette.accOrange))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 10) == CodexTheme.readableAccentToken(CodexTheme.Palette.accRed))
    }

    @Test
    func progressPaletteUsesExactBoundaryThresholds() {
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 24) == CodexTheme.readableAccentToken(CodexTheme.Palette.accRed))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 25) == CodexTheme.readableAccentToken(CodexTheme.Palette.accOrange))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 49) == CodexTheme.readableAccentToken(CodexTheme.Palette.accOrange))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 50) == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 74) == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 75) == CodexTheme.readableAccentToken(CodexTheme.Palette.accGreen))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 99) == CodexTheme.readableAccentToken(CodexTheme.Palette.accGreen))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 100) == CodexTheme.readableAccentToken(CodexTheme.Palette.accPurple))
        #expect(CodexTheme.progressTextToken(forRemainingPercent: 101) == CodexTheme.readableAccentToken(CodexTheme.Palette.accGreen))
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

        #expect(calm == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(warning == CodexTheme.readableAccentToken(CodexTheme.Palette.accOrange))
        #expect(critical == CodexTheme.readableAccentToken(CodexTheme.Palette.accRed))
        #expect(expired == CodexTheme.readableAccentToken(CodexTheme.Palette.accRed))
        #expect(CodexTheme.expiryEmphasisToken(for: nil, referenceDate: referenceDate) == nil)
    }

    @Test
    func resetPaletteStaysWarmForHighlightedResetValues() {
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: nil) == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 82) == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 44) == CodexTheme.readableAccentToken(CodexTheme.Palette.accOrange))
        #expect(CodexTheme.resetEmphasisToken(forRemainingPercent: 12) == CodexTheme.readableAccentToken(CodexTheme.Palette.accRed))
    }

    @Test
    func resetCountdownPaletteUsesInfoBlueInDarkThemes() {
        #expect(CodexTheme.resetCountdownEmphasisToken() == CodexTheme.readableAccentToken(CodexTheme.Palette.accBlue))
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

private let cardSurfaceTiers: [(name: String, tier: CodexSurfaceTier)] = [
    ("strong", .strong),
    ("regular", .regular),
    ("nested", .nested),
    ("subtle", .subtle),
]

private func usefulTextRoles(for preset: CodexThemePreset) -> [(name: String, token: CodexColorToken)] {
    let palette = CodexTheme.palette(for: preset)
    return [
        ("primary", palette.primaryText),
        ("muted", palette.mutedText),
        ("quiet", palette.quietText),
        ("support", palette.supportText),
        ("dataLabel", palette.dataLabelText),
        ("dataValue", palette.dataValueText),
        ("oneTimePasswordCode", CodexTheme.oneTimePasswordCodeTextToken(preset: preset)),
        ("oneTimePasswordStatus", CodexTheme.oneTimePasswordStatusTextToken(preset: preset)),
        ("oneTimePasswordMask", CodexTheme.oneTimePasswordMaskFillToken(preset: preset)),
    ]
}

private func densePanelAccentTextRoles(for preset: CodexThemePreset) -> [(name: String, token: CodexColorToken)] {
    let palette = CodexTheme.palette(for: preset)
    return [
        ("action", CodexTheme.actionTextToken(preset: preset)),
        ("utilityAction", CodexTheme.utilityActionTextToken(preset: preset)),
        ("success", CodexTheme.successTextToken(preset: preset)),
        ("danger", CodexTheme.dangerTextToken(preset: preset)),
        ("info", CodexTheme.readableAccentToken(palette.accBlue, preset: preset)),
        ("fullLimitData", CodexTheme.progressTextToken(forRemainingPercent: 100, preset: preset)),
        ("healthyData", CodexTheme.progressTextToken(forRemainingPercent: 90, preset: preset)),
        ("warningData", CodexTheme.progressTextToken(forRemainingPercent: 62, preset: preset)),
        ("dangerData", CodexTheme.progressTextToken(forRemainingPercent: 12, preset: preset)),
        ("resetCountdown", CodexTheme.resetCountdownEmphasisToken(preset: preset)),
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
