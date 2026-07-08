import AppKit
import CoreText
import SwiftUI

struct CodexColorToken: Sendable, Equatable {
    let hex: String

    var color: Color {
        Color(hex: hex)
    }

    func color(alpha: Double) -> Color {
        Color(hex: hex, alpha: alpha)
    }

    func mixed(with other: CodexColorToken, fraction: Double) -> CodexColorToken {
        CodexColorToken(
            hex: color
                .mixed(with: other.color, fraction: fraction)
                .hexString
        )
    }
}

enum CodexSurfaceRole: Sendable {
    case panel
    case dialog
}

enum CodexSurfaceTier: Sendable {
    case strong
    case regular
    case nested
    case subtle
}

struct CodexShadowStyle: Sendable {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

enum CodexStatusTone: String, Sendable, Equatable {
    case neutral
    case info
    case success
    case warning
    case critical

    var accentToken: CodexColorToken {
        CodexTheme.statusAccentToken(for: self)
    }

    var accentColor: Color {
        accentToken.color
    }

    var foregroundColor: Color {
        CodexTheme.statusForegroundToken(for: self).color
    }

    var backgroundColor: Color {
        accentToken.color(alpha: CodexTheme.isDarkTheme ? 0.14 : 0.10)
    }

    var borderColor: Color {
        accentToken.color(alpha: CodexTheme.isDarkTheme ? 0.34 : 0.46)
    }
}

enum CodexProfileTagTone: String, CaseIterable, Sendable, Equatable {
    case active
    case needAction
    case pending

    var accentColor: Color {
        CodexTheme.profileTagAccentToken(for: self).color
    }

    var foregroundColor: Color {
        CodexTheme.profileTagTextToken(for: self).color
    }

    func fillColor(isSelected: Bool = true) -> Color {
        CodexTheme.profileTagFillToken(for: self, isSelected: isSelected).color
    }

    func borderColor(isSelected: Bool = true) -> Color {
        CodexTheme.profileTagBorderToken(for: self, isSelected: isSelected).color
    }
}

enum CodexControlTone: Sendable {
    case primary
    case secondary
    case danger
    case quiet
}

enum CodexThemeVariant: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:
            return "Dark"
        case .light:
            return "Light"
        }
    }
}

enum CodexThemeAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .dark:
            return "Dark"
        case .light:
            return "Light"
        }
    }

    var forcedVariant: CodexThemeVariant? {
        switch self {
        case .system:
            return nil
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }
}

enum CodexThemeContrast: String, CaseIterable, Identifiable, Sendable {
    case hard
    case medium
    case soft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hard:
            return "Hard"
        case .medium:
            return "Medium"
        case .soft:
            return "Soft"
        }
    }
}

struct CodexThemePreset: Identifiable, Sendable, Equatable {
    let variant: CodexThemeVariant
    let contrast: CodexThemeContrast

    var id: String {
        "\(variant.rawValue)-\(contrast.rawValue)"
    }

    var title: String {
        "\(variant.title) \(contrast.title)"
    }

    static let defaultPreset = CodexThemePreset(variant: .dark, contrast: .hard)

    static let allCases: [CodexThemePreset] = CodexThemeVariant.allCases.flatMap { variant in
        CodexThemeContrast.allCases.map { contrast in
            CodexThemePreset(variant: variant, contrast: contrast)
        }
    }
}

enum CodexThemeSettings {
    enum Keys {
        static let appearanceMode = "CodexPlusBar.theme.appearanceMode"
        static let contrast = "CodexPlusBar.theme.contrast"
    }

    static let defaultAppearanceMode = CodexThemeAppearanceMode.dark
    static let defaultContrast = CodexThemeContrast.hard

    static func appearanceMode(in userDefaults: UserDefaults = .standard) -> CodexThemeAppearanceMode {
        guard let rawValue = userDefaults.string(forKey: Keys.appearanceMode),
              let mode = CodexThemeAppearanceMode(rawValue: rawValue) else {
            return defaultAppearanceMode
        }

        return mode
    }

    static func contrast(in userDefaults: UserDefaults = .standard) -> CodexThemeContrast {
        guard let rawValue = userDefaults.string(forKey: Keys.contrast),
              let contrast = CodexThemeContrast(rawValue: rawValue) else {
            return defaultContrast
        }

        return contrast
    }

    static func systemAppearanceVariant(in userDefaults: UserDefaults = .standard) -> CodexThemeVariant {
        userDefaults.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }
}

struct CodexThemeRefreshContext: Equatable {
    let appearanceMode: CodexThemeAppearanceMode
    let contrast: CodexThemeContrast
    let systemVariant: CodexThemeVariant

    init(
        appearanceMode: CodexThemeAppearanceMode = CodexThemeSettings.defaultAppearanceMode,
        contrast: CodexThemeContrast = CodexThemeSettings.defaultContrast,
        systemVariant: CodexThemeVariant = CodexThemeSettings.systemAppearanceVariant()
    ) {
        self.appearanceMode = appearanceMode
        self.contrast = contrast
        self.systemVariant = systemVariant
    }

    var variant: CodexThemeVariant {
        appearanceMode.forcedVariant ?? systemVariant
    }

    var preset: CodexThemePreset {
        CodexThemePreset(variant: variant, contrast: contrast)
    }

    var preferredColorScheme: ColorScheme? {
        appearanceMode.preferredColorScheme
    }

    var identityResetKey: String? {
        nil
    }
}

struct CodexEverforestPalette: Sendable, Equatable {
    let variant: CodexThemeVariant
    let contrast: CodexThemeContrast
    let bgDim: CodexColorToken
    let bg0: CodexColorToken
    let bg1: CodexColorToken
    let bg2: CodexColorToken
    let bg3: CodexColorToken
    let bg4: CodexColorToken
    let bg5: CodexColorToken
    let bgVisual: CodexColorToken
    let bgRed: CodexColorToken
    let bgYellow: CodexColorToken
    let bgGreen: CodexColorToken
    let bgBlue: CodexColorToken
    let bgPurple: CodexColorToken
    let fg: CodexColorToken
    let strongText: CodexColorToken
    let gray0: CodexColorToken
    let gray1: CodexColorToken
    let gray2: CodexColorToken
    let accOrange: CodexColorToken
    let accRed: CodexColorToken
    let accYellow: CodexColorToken
    let accGreen: CodexColorToken
    let accAqua: CodexColorToken
    let accBlue: CodexColorToken
    let accPurple: CodexColorToken

    var isDark: Bool {
        variant == .dark
    }

    var primaryText: CodexColorToken {
        switch (variant, contrast) {
        case (.light, .medium):
            return fg.mixed(with: strongText, fraction: 0.06)
        case (.light, .soft):
            return fg.mixed(with: strongText, fraction: 0.18)
        default:
            return fg
        }
    }

    var dataLabelText: CodexColorToken {
        primaryText
    }

    var dataValueText: CodexColorToken {
        strongText
    }

    var mutedText: CodexColorToken {
        dataLabelText
    }

    var quietText: CodexColorToken {
        dataLabelText
    }

    var supportText: CodexColorToken {
        dataLabelText
    }

    var onAccentText: CodexColorToken {
        CodexColorToken(hex: "#1E2326")
    }

    var accPink: CodexColorToken {
        accPurple
    }
}

enum CodexTheme {
    enum Palette {
        static let bg0 = CodexColorToken(hex: "#1E2326")
        static let bg1 = CodexColorToken(hex: "#272E33")
        static let bg2 = CodexColorToken(hex: "#2E383C")
        static let bg3 = CodexColorToken(hex: "#374145")
        static let bg4 = CodexColorToken(hex: "#414B50")
        static let bg5 = CodexColorToken(hex: "#495156")
        static let bg6 = CodexColorToken(hex: "#4F5B58")
        static let bgRose = CodexColorToken(hex: "#4C3743")
        static let bgUmber = CodexColorToken(hex: "#493B40")
        static let bgMoss = CodexColorToken(hex: "#45443C")
        static let bgOlive = CodexColorToken(hex: "#3C4841")
        static let bgSlate = CodexColorToken(hex: "#384B55")
        static let bgPlum = CodexColorToken(hex: "#463F48")

        static let fg = CodexColorToken(hex: "#D3C6AA")
        static let gray0 = CodexColorToken(hex: "#7A8478")
        static let gray1 = CodexColorToken(hex: "#859289")
        static let gray2 = CodexColorToken(hex: "#9DA9A0")

        static let accOrange = CodexColorToken(hex: "#E69875")
        static let accRed = CodexColorToken(hex: "#E67E80")
        static let accYellow = CodexColorToken(hex: "#DBBC7F")
        static let accGreen = CodexColorToken(hex: "#A7C080")
        static let accAqua = CodexColorToken(hex: "#83C092")
        static let accBlue = CodexColorToken(hex: "#7FBBB3")
        static let accPurple = CodexColorToken(hex: "#D699B6")
        static let accPink = accPurple
    }

    static func palette(for preset: CodexThemePreset) -> CodexEverforestPalette {
        switch (preset.variant, preset.contrast) {
        case (.dark, .hard):
            return CodexEverforestPalette(
                variant: .dark,
                contrast: .hard,
                bgDim: CodexColorToken(hex: "#1E2326"),
                bg0: CodexColorToken(hex: "#272E33"),
                bg1: CodexColorToken(hex: "#2E383C"),
                bg2: CodexColorToken(hex: "#374145"),
                bg3: CodexColorToken(hex: "#414B50"),
                bg4: CodexColorToken(hex: "#495156"),
                bg5: CodexColorToken(hex: "#4F5B58"),
                bgVisual: CodexColorToken(hex: "#4C3743"),
                bgRed: CodexColorToken(hex: "#493B40"),
                bgYellow: CodexColorToken(hex: "#45443C"),
                bgGreen: CodexColorToken(hex: "#3C4841"),
                bgBlue: CodexColorToken(hex: "#384B55"),
                bgPurple: CodexColorToken(hex: "#463F48"),
                fg: CodexColorToken(hex: "#D3C6AA"),
                strongText: CodexColorToken(hex: "#F2EFDF"),
                gray0: CodexColorToken(hex: "#7A8478"),
                gray1: CodexColorToken(hex: "#859289"),
                gray2: CodexColorToken(hex: "#9DA9A0"),
                accOrange: CodexColorToken(hex: "#E69875"),
                accRed: CodexColorToken(hex: "#E67E80"),
                accYellow: CodexColorToken(hex: "#DBBC7F"),
                accGreen: CodexColorToken(hex: "#A7C080"),
                accAqua: CodexColorToken(hex: "#83C092"),
                accBlue: CodexColorToken(hex: "#7FBBB3"),
                accPurple: CodexColorToken(hex: "#D699B6")
            )
        case (.dark, .medium):
            return CodexEverforestPalette(
                variant: .dark,
                contrast: .medium,
                bgDim: CodexColorToken(hex: "#232A2E"),
                bg0: CodexColorToken(hex: "#2D353B"),
                bg1: CodexColorToken(hex: "#343F44"),
                bg2: CodexColorToken(hex: "#3D484D"),
                bg3: CodexColorToken(hex: "#475258"),
                bg4: CodexColorToken(hex: "#4F585E"),
                bg5: CodexColorToken(hex: "#56635F"),
                bgVisual: CodexColorToken(hex: "#543A48"),
                bgRed: CodexColorToken(hex: "#514045"),
                bgYellow: CodexColorToken(hex: "#4D4C43"),
                bgGreen: CodexColorToken(hex: "#425047"),
                bgBlue: CodexColorToken(hex: "#3A515D"),
                bgPurple: CodexColorToken(hex: "#4A444E"),
                fg: CodexColorToken(hex: "#D3C6AA"),
                strongText: CodexColorToken(hex: "#EFEBD4"),
                gray0: CodexColorToken(hex: "#7A8478"),
                gray1: CodexColorToken(hex: "#859289"),
                gray2: CodexColorToken(hex: "#9DA9A0"),
                accOrange: CodexColorToken(hex: "#E69875"),
                accRed: CodexColorToken(hex: "#E67E80"),
                accYellow: CodexColorToken(hex: "#DBBC7F"),
                accGreen: CodexColorToken(hex: "#A7C080"),
                accAqua: CodexColorToken(hex: "#83C092"),
                accBlue: CodexColorToken(hex: "#7FBBB3"),
                accPurple: CodexColorToken(hex: "#D699B6")
            )
        case (.dark, .soft):
            return CodexEverforestPalette(
                variant: .dark,
                contrast: .soft,
                bgDim: CodexColorToken(hex: "#293136"),
                bg0: CodexColorToken(hex: "#333C43"),
                bg1: CodexColorToken(hex: "#3A464C"),
                bg2: CodexColorToken(hex: "#434F55"),
                bg3: CodexColorToken(hex: "#4D5960"),
                bg4: CodexColorToken(hex: "#555F66"),
                bg5: CodexColorToken(hex: "#5D6B66"),
                bgVisual: CodexColorToken(hex: "#5C3F4F"),
                bgRed: CodexColorToken(hex: "#59464C"),
                bgYellow: CodexColorToken(hex: "#55544A"),
                bgGreen: CodexColorToken(hex: "#48584E"),
                bgBlue: CodexColorToken(hex: "#3F5865"),
                bgPurple: CodexColorToken(hex: "#4E4953"),
                fg: CodexColorToken(hex: "#D3C6AA"),
                strongText: CodexColorToken(hex: "#F3EAD3"),
                gray0: CodexColorToken(hex: "#7A8478"),
                gray1: CodexColorToken(hex: "#859289"),
                gray2: CodexColorToken(hex: "#9DA9A0"),
                accOrange: CodexColorToken(hex: "#E69875"),
                accRed: CodexColorToken(hex: "#E67E80"),
                accYellow: CodexColorToken(hex: "#DBBC7F"),
                accGreen: CodexColorToken(hex: "#A7C080"),
                accAqua: CodexColorToken(hex: "#83C092"),
                accBlue: CodexColorToken(hex: "#7FBBB3"),
                accPurple: CodexColorToken(hex: "#D699B6")
            )
        case (.light, .hard):
            return CodexEverforestPalette(
                variant: .light,
                contrast: .hard,
                bgDim: CodexColorToken(hex: "#F2EFDF"),
                bg0: CodexColorToken(hex: "#FFFBEF"),
                bg1: CodexColorToken(hex: "#F8F5E4"),
                bg2: CodexColorToken(hex: "#F2EFDF"),
                bg3: CodexColorToken(hex: "#EDEADA"),
                bg4: CodexColorToken(hex: "#E8E5D5"),
                bg5: CodexColorToken(hex: "#BEC5B2"),
                bgVisual: CodexColorToken(hex: "#F0F2D4"),
                bgRed: CodexColorToken(hex: "#FFE7DE"),
                bgYellow: CodexColorToken(hex: "#FEF2D5"),
                bgGreen: CodexColorToken(hex: "#F3F5D9"),
                bgBlue: CodexColorToken(hex: "#ECF5ED"),
                bgPurple: CodexColorToken(hex: "#FCECED"),
                fg: CodexColorToken(hex: "#5C6A72"),
                strongText: CodexColorToken(hex: "#1E2326"),
                gray0: CodexColorToken(hex: "#A6B0A0"),
                gray1: CodexColorToken(hex: "#939F91"),
                gray2: CodexColorToken(hex: "#829181"),
                accOrange: CodexColorToken(hex: "#F57D26"),
                accRed: CodexColorToken(hex: "#F85552"),
                accYellow: CodexColorToken(hex: "#DFA000"),
                accGreen: CodexColorToken(hex: "#8DA101"),
                accAqua: CodexColorToken(hex: "#35A77C"),
                accBlue: CodexColorToken(hex: "#3A94C5"),
                accPurple: CodexColorToken(hex: "#DF69BA")
            )
        case (.light, .medium):
            return CodexEverforestPalette(
                variant: .light,
                contrast: .medium,
                bgDim: CodexColorToken(hex: "#EFEBD4"),
                bg0: CodexColorToken(hex: "#FDF6E3"),
                bg1: CodexColorToken(hex: "#F4F0D9"),
                bg2: CodexColorToken(hex: "#EFEBD4"),
                bg3: CodexColorToken(hex: "#E6E2CC"),
                bg4: CodexColorToken(hex: "#E0DCC7"),
                bg5: CodexColorToken(hex: "#BDC3AF"),
                bgVisual: CodexColorToken(hex: "#EAEDC8"),
                bgRed: CodexColorToken(hex: "#FDE3DA"),
                bgYellow: CodexColorToken(hex: "#FAEDCD"),
                bgGreen: CodexColorToken(hex: "#F0F1D2"),
                bgBlue: CodexColorToken(hex: "#E9F0E9"),
                bgPurple: CodexColorToken(hex: "#FAE8E2"),
                fg: CodexColorToken(hex: "#5C6A72"),
                strongText: CodexColorToken(hex: "#232A2E"),
                gray0: CodexColorToken(hex: "#A6B0A0"),
                gray1: CodexColorToken(hex: "#939F91"),
                gray2: CodexColorToken(hex: "#829181"),
                accOrange: CodexColorToken(hex: "#F57D26"),
                accRed: CodexColorToken(hex: "#F85552"),
                accYellow: CodexColorToken(hex: "#DFA000"),
                accGreen: CodexColorToken(hex: "#8DA101"),
                accAqua: CodexColorToken(hex: "#35A77C"),
                accBlue: CodexColorToken(hex: "#3A94C5"),
                accPurple: CodexColorToken(hex: "#DF69BA")
            )
        case (.light, .soft):
            return CodexEverforestPalette(
                variant: .light,
                contrast: .soft,
                bgDim: CodexColorToken(hex: "#E5DFC5"),
                bg0: CodexColorToken(hex: "#F3EAD3"),
                bg1: CodexColorToken(hex: "#EAE4CA"),
                bg2: CodexColorToken(hex: "#E5DFC5"),
                bg3: CodexColorToken(hex: "#DDD8BE"),
                bg4: CodexColorToken(hex: "#D8D3BA"),
                bg5: CodexColorToken(hex: "#B9C0AB"),
                bgVisual: CodexColorToken(hex: "#E1E4BD"),
                bgRed: CodexColorToken(hex: "#FADBD0"),
                bgYellow: CodexColorToken(hex: "#F1E4C5"),
                bgGreen: CodexColorToken(hex: "#E5E6C5"),
                bgBlue: CodexColorToken(hex: "#E1E7DD"),
                bgPurple: CodexColorToken(hex: "#F1DDD4"),
                fg: CodexColorToken(hex: "#5C6A72"),
                strongText: CodexColorToken(hex: "#293136"),
                gray0: CodexColorToken(hex: "#A6B0A0"),
                gray1: CodexColorToken(hex: "#939F91"),
                gray2: CodexColorToken(hex: "#829181"),
                accOrange: CodexColorToken(hex: "#F57D26"),
                accRed: CodexColorToken(hex: "#F85552"),
                accYellow: CodexColorToken(hex: "#DFA000"),
                accGreen: CodexColorToken(hex: "#8DA101"),
                accAqua: CodexColorToken(hex: "#35A77C"),
                accBlue: CodexColorToken(hex: "#3A94C5"),
                accPurple: CodexColorToken(hex: "#DF69BA")
            )
        }
    }

    static var activePreset: CodexThemePreset {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return .defaultPreset
        }

        return CodexThemeRefreshContext(
            appearanceMode: CodexThemeSettings.appearanceMode(),
            contrast: CodexThemeSettings.contrast()
        ).preset
    }

    static var activeRefreshContext: CodexThemeRefreshContext {
        CodexThemeRefreshContext(
            appearanceMode: CodexThemeSettings.appearanceMode(),
            contrast: CodexThemeSettings.contrast()
        )
    }

    static var activePalette: CodexEverforestPalette {
        palette(for: activePreset)
    }

    static var isDarkTheme: Bool {
        activePalette.isDark
    }

    static var preferredColorScheme: ColorScheme? {
        activeRefreshContext.preferredColorScheme
    }

    enum Radius {
        static let strongSurface: CGFloat = 18
        static let surface: CGFloat = 16
        static let nested: CGFloat = 12
        static let field: CGFloat = 10
        static let button: CGFloat = 10
        static let icon: CGFloat = 10
        static let badge: CGFloat = 8
        static let progress: CGFloat = 5
    }

    enum Spacing {
        static let outerPage: CGFloat = 26
        static let panel: CGFloat = 16
        static let section: CGFloat = 16
        static let row: CGFloat = 12
        static let content: CGFloat = 20
        static let micro: CGFloat = 6
    }

    static var bg0: Color { activePalette.bgDim.color }
    static var bg1: Color { activePalette.bg0.color }
    static var bg2: Color { activePalette.bg1.color }
    static var bg3: Color { activePalette.bg2.color }
    static var bg4: Color { activePalette.bg3.color }
    static var primaryTextToken: CodexColorToken { activePalette.primaryText }
    static var headingTextToken: CodexColorToken { activePalette.strongText }
    static var mutedTextToken: CodexColorToken { activePalette.mutedText }
    static var quietTextToken: CodexColorToken { activePalette.quietText }
    static var disabledTextToken: CodexColorToken { activePalette.quietText }
    static var supportTextToken: CodexColorToken { activePalette.supportText }
    static var dataLabelTextToken: CodexColorToken { activePalette.dataLabelText }
    static var dataValueTextToken: CodexColorToken { activePalette.dataValueText }
    static var canvasFillToken: CodexColorToken { canvasFillToken(for: activePreset) }
    static var shellFillToken: CodexColorToken { shellFillToken(for: activePreset) }
    static var shellDialogFillToken: CodexColorToken { shellFillToken(for: activePreset) }

    static var primaryText: Color { primaryTextToken.color }
    static var headingText: Color { headingTextToken.color }
    static var mutedText: Color { mutedTextToken.color }
    static var quietText: Color { quietTextToken.color }
    static var disabledText: Color { disabledTextToken.color }
    static var supportText: Color { supportTextToken.color }
    static var dataLabelText: Color { dataLabelTextToken.color }
    static var dataValueText: Color { dataValueTextToken.color }
    static var actionText: Color { actionTextToken().color }
    static var utilityActionText: Color { utilityActionTextToken().color }
    static var successText: Color { successTextToken().color }
    static var dangerText: Color { dangerTextToken().color }
    static var accentOrange: Color { activePalette.accOrange.color }
    static var accentRed: Color { activePalette.accRed.color }
    static var accentYellow: Color { activePalette.accYellow.color }
    static var accentGreen: Color { activePalette.accGreen.color }
    static var accentAqua: Color { activePalette.accAqua.color }
    static var accentBlue: Color { activePalette.accBlue.color }
    static var accentPurple: Color { activePalette.accPurple.color }
    static var accentPink: Color { activePalette.accPink.color }
    static var accentInk: Color { activePalette.onAccentText.color }

    static let shellCornerRadius = Radius.strongSurface
    static let sectionCornerRadius = Radius.surface
    static let fieldCornerRadius = Radius.field
    static let controlCornerRadius = Radius.button
    static let iconCornerRadius = Radius.icon
    static let thinBarCornerRadius = Radius.progress
    static let profileTagBorderLineWidth: CGFloat = 0.75

    static let panelPadding = Spacing.panel
    static let sectionSpacing = Spacing.section
    static let rowSpacing = Spacing.row
    static let contentSpacing = Spacing.content
    static let chromePadding = Spacing.outerPage

    static var surfaceLine: Color { surfaceBorder(for: .regular) }
    static var border: Color { surfaceLine }
    static var warmBorder: Color { accentOrange.opacity(isDarkTheme ? 0.28 : 0.46) }
    static var focusRing: Color { accentOrange.opacity(isDarkTheme ? 0.38 : 0.54) }
    static var shadowPrimary: Color { Color.black.opacity(isDarkTheme ? 0.34 : 0.12) }
    static var primaryActionTokens: [CodexColorToken] {
        [activePalette.accOrange, activePalette.accRed]
    }

    static func readableAccentToken(
        _ token: CodexColorToken,
        preset: CodexThemePreset = activePreset,
        additionalBackgrounds: [CodexColorToken] = []
    ) -> CodexColorToken {
        let palette = palette(for: preset)
        let backgrounds = readableAccentBackgroundTokens(for: preset) + additionalBackgrounds
        let minimumNormalTextContrast = 5.0

        if token.passesContrast(minimumNormalTextContrast, against: backgrounds) {
            return token
        }

        for step in 1...16 {
            let candidate = token.mixed(with: palette.strongText, fraction: Double(step) * 0.05)
            if candidate.passesContrast(minimumNormalTextContrast, against: backgrounds) {
                return candidate
            }
        }

        return palette.strongText
    }

    static func actionTextToken(preset: CodexThemePreset = activePreset) -> CodexColorToken {
        readableAccentToken(palette(for: preset).accOrange, preset: preset)
    }

    static func utilityActionTextToken(preset: CodexThemePreset = activePreset) -> CodexColorToken {
        readableAccentToken(palette(for: preset).accBlue, preset: preset)
    }

    static func successTextToken(preset: CodexThemePreset = activePreset) -> CodexColorToken {
        readableAccentToken(palette(for: preset).accAqua, preset: preset)
    }

    static func dangerTextToken(preset: CodexThemePreset = activePreset) -> CodexColorToken {
        readableAccentToken(palette(for: preset).accRed, preset: preset)
    }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: primaryActionTokens.map(\.color),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static var warmGradient: LinearGradient {
        LinearGradient(
            colors: [accentOrange, accentRed],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var shellFill: Color { shellFillToken.color }
    static var shellDialogFill: Color { shellDialogFillToken.color }
    static var shellMutedFill: Color { surfaceFill(for: .subtle) }
    static var sectionFill: Color { surfaceFill(for: .regular) }
    static var sectionMutedFill: Color { surfaceFill(for: .nested) }

    static func shellFill(for role: CodexSurfaceRole) -> Color {
        switch role {
        case .panel:
            shellFill
        case .dialog:
            shellDialogFill
        }
    }

    static func canvasFillToken(for preset: CodexThemePreset) -> CodexColorToken {
        palette(for: preset).bgDim
    }

    static func shellFillToken(for preset: CodexThemePreset) -> CodexColorToken {
        palette(for: preset).bg0
    }

    static func surfaceFill(for tier: CodexSurfaceTier) -> Color {
        surfaceToken(for: tier).color
    }

    static func cardFill(for tier: CodexSurfaceTier) -> Color {
        cardFillToken(for: tier).color
    }

    static func cardFillToken(for tier: CodexSurfaceTier) -> CodexColorToken {
        cardFillToken(for: tier, preset: activePreset)
    }

    static func cardFillToken(
        for _: CodexSurfaceTier,
        preset: CodexThemePreset
    ) -> CodexColorToken {
        palette(for: preset).bg0
    }

    static func surfaceToken(for tier: CodexSurfaceTier) -> CodexColorToken {
        surfaceToken(for: tier, preset: activePreset)
    }

    static func surfaceToken(for tier: CodexSurfaceTier, preset: CodexThemePreset) -> CodexColorToken {
        let palette = palette(for: preset)

        switch tier {
        case .strong:
            return palette.isDark ? palette.bg2 : palette.bg3
        case .regular:
            return palette.bg1
        case .nested:
            return palette.bg2
        case .subtle:
            return palette.bg0.mixed(with: palette.bg1, fraction: 0.45)
        }
    }

    static func surfaceBorder(for tier: CodexSurfaceTier, accent: Color? = nil) -> Color {
        surfaceBorder(for: tier, preset: activePreset, accent: accent)
    }

    static func surfaceBorder(
        for tier: CodexSurfaceTier,
        preset: CodexThemePreset,
        accent: Color? = nil
    ) -> Color {
        let palette = palette(for: preset)

        if let accent {
            return accent.opacity(tier == .strong ? 0.36 : 0.28)
        }

        switch tier {
        case .strong:
            return palette.gray2.color(alpha: palette.isDark ? 0.42 : 0.62)
        case .regular:
            return palette.gray1.color(alpha: palette.isDark ? 0.34 : 0.56)
        case .nested:
            return palette.gray1.color(alpha: palette.isDark ? 0.28 : 0.50)
        case .subtle:
            return palette.gray1.color(alpha: palette.isDark ? 0.30 : 0.44)
        }
    }

    static func surfaceSheen(for tier: CodexSurfaceTier) -> LinearGradient {
        surfaceSheen(for: tier, preset: activePreset)
    }

    static func surfaceSheen(for tier: CodexSurfaceTier, preset: CodexThemePreset) -> LinearGradient {
        let opacity = surfaceSheenOpacity(for: tier, preset: preset)

        return LinearGradient(
            colors: [Color.white.opacity(opacity.top), Color.white.opacity(opacity.middle), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func surfaceSheenOpacity(
        for tier: CodexSurfaceTier,
        preset: CodexThemePreset
    ) -> (top: Double, middle: Double) {
        let palette = palette(for: preset)
        switch tier {
        case .strong:
            return palette.isDark ? (0.022, 0.007) : (0.16, 0.06)
        case .regular:
            return palette.isDark ? (0.016, 0.005) : (0.13, 0.05)
        case .nested:
            return palette.isDark ? (0.012, 0.004) : (0.10, 0.04)
        case .subtle:
            return palette.isDark ? (0.006, 0.0) : (0.08, 0.0)
        }
    }

    static func shadow(for tier: CodexSurfaceTier) -> CodexShadowStyle {
        shadow(for: tier, preset: activePreset)
    }

    static func shadow(for tier: CodexSurfaceTier, preset: CodexThemePreset) -> CodexShadowStyle {
        let palette = palette(for: preset)

        switch tier {
        case .strong:
            return CodexShadowStyle(color: .black.opacity(palette.isDark ? 0.30 : 0.12), radius: 18, y: 10)
        case .regular:
            return CodexShadowStyle(color: .black.opacity(palette.isDark ? 0.24 : 0.10), radius: 14, y: 8)
        case .nested:
            return CodexShadowStyle(color: .black.opacity(palette.isDark ? 0.18 : 0.08), radius: 10, y: 5)
        case .subtle:
            return CodexShadowStyle(color: .black.opacity(palette.isDark ? 0.12 : 0.06), radius: 6, y: 3)
        }
    }

    static func cornerRadius(for tier: CodexSurfaceTier) -> CGFloat {
        switch tier {
        case .strong:
            return Radius.strongSurface
        case .regular:
            return Radius.surface
        case .nested:
            return Radius.nested
        case .subtle:
            return Radius.field
        }
    }

    static func statusTone(for authState: AuthState, limitReached: Bool = false) -> CodexStatusTone {
        if authState == .signedIn, limitReached {
            return .warning
        }

        switch authState {
        case .signedIn:
            return .success
        case .signingIn:
            return .info
        case .noAccounts:
            return .warning
        case .signedOut:
            return .warning
        case .expired:
            return .warning
        case .unsupported:
            return .critical
        }
    }

    static func badgeTitle(for authState: AuthState) -> String {
        switch authState {
        case .signedIn:
            return "Ready"
        case .signingIn:
            return "Checking"
        case .noAccounts:
            return "No accounts"
        case .signedOut:
            return "No session"
        case .expired:
            return "Expired"
        case .unsupported:
            return "Changed"
        }
    }

    static func statusAccentToken(for tone: CodexStatusTone) -> CodexColorToken {
        switch tone {
        case .neutral:
            activePalette.gray1
        case .info:
            activePalette.accBlue
        case .success:
            activePalette.accAqua
        case .warning:
            activePalette.accYellow
        case .critical:
            activePalette.accRed
        }
    }

    static func statusForegroundToken(for tone: CodexStatusTone) -> CodexColorToken {
        tone == .neutral ? primaryTextToken : readableAccentToken(statusAccentToken(for: tone))
    }

    static func profileTagAccentToken(
        for tone: CodexProfileTagTone,
        preset: CodexThemePreset = activePreset
    ) -> CodexColorToken {
        let palette = palette(for: preset)

        switch tone {
        case .active:
            return palette.accGreen
        case .needAction:
            return palette.accRed
        case .pending:
            return palette.accYellow
        }
    }

    static func profileTagTextToken(
        for tone: CodexProfileTagTone,
        preset: CodexThemePreset = activePreset
    ) -> CodexColorToken {
        readableAccentToken(
            profileTagAccentToken(for: tone, preset: preset),
            preset: preset,
            additionalBackgrounds: [
                profileTagFillToken(for: tone, isSelected: true, preset: preset),
                profileTagFillToken(for: tone, isSelected: false, preset: preset),
            ]
        )
    }

    static func profileTagFillToken(
        for tone: CodexProfileTagTone,
        isSelected: Bool,
        preset: CodexThemePreset = activePreset
    ) -> CodexColorToken {
        let palette = palette(for: preset)

        guard isSelected else {
            return surfaceToken(for: .subtle, preset: preset)
        }

        switch tone {
        case .active:
            return palette.bgGreen
        case .needAction:
            return palette.bgRed
        case .pending:
            return palette.bgYellow
        }
    }

    static func profileTagBorderToken(
        for tone: CodexProfileTagTone,
        isSelected: Bool,
        preset: CodexThemePreset = activePreset
    ) -> CodexColorToken {
        let palette = palette(for: preset)
        let fill = profileTagFillToken(for: tone, isSelected: isSelected, preset: preset)
        let accent = profileTagAccentToken(for: tone, preset: preset)
        let fraction = isSelected
            ? (palette.isDark ? 0.32 : 0.28)
            : (palette.isDark ? 0.12 : 0.10)

        return fill.mixed(with: accent, fraction: fraction)
    }

    static func progressAccentToken(forRemainingPercent remainingPercent: Int, preset: CodexThemePreset = activePreset) -> CodexColorToken {
        let palette = palette(for: preset)
        switch clamped(remainingPercent) {
        case 0..<25:
            return palette.accRed
        case 25..<50:
            return palette.accOrange
        case 50..<75:
            return palette.accYellow
        default:
            return palette.accGreen
        }
    }

    static func progressTextToken(
        forRemainingPercent remainingPercent: Int,
        preset: CodexThemePreset = activePreset
    ) -> CodexColorToken {
        let accent = progressAccentToken(forRemainingPercent: remainingPercent, preset: preset)
        return readableAccentToken(accent, preset: preset)
    }

    static func usagePercentageColor(forRemainingPercent remainingPercent: Int) -> Color {
        progressTextToken(forRemainingPercent: remainingPercent).color
    }

    static func progressStopTokens(forRemainingPercent remainingPercent: Int) -> [CodexColorToken] {
        let dominant = progressAccentToken(forRemainingPercent: remainingPercent)
        return [
            activePalette.accRed.mixed(with: dominant, fraction: 0.20),
            activePalette.accOrange.mixed(with: dominant, fraction: 0.24),
            activePalette.accYellow.mixed(with: dominant, fraction: 0.22),
            activePalette.accGreen.mixed(with: dominant, fraction: 0.18),
        ]
    }

    static func progressGradient(forRemainingPercent remainingPercent: Int) -> LinearGradient {
        let tokens = progressStopTokens(forRemainingPercent: remainingPercent)
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: tokens[0].color, location: 0.0),
                .init(color: tokens[1].color, location: 0.34),
                .init(color: tokens[2].color, location: 0.68),
                .init(color: tokens[3].color, location: 1.0),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static func expiryEmphasisToken(
        for date: Date?,
        referenceDate: Date = .now,
        preset: CodexThemePreset = activePreset
    ) -> CodexColorToken? {
        guard let date else {
            return nil
        }

        let palette = palette(for: preset)
        let remainingSeconds = Int(date.timeIntervalSince(referenceDate).rounded(.down))
        let criticalThresholdSeconds = 3 * 24 * 3_600
        let warningThresholdSeconds = 7 * 24 * 3_600

        if remainingSeconds <= 0 {
            return readableAccentToken(palette.accRed, preset: preset)
        }

        if remainingSeconds >= warningThresholdSeconds {
            return readableAccentToken(palette.accYellow, preset: preset)
        }

        if remainingSeconds >= criticalThresholdSeconds {
            return readableAccentToken(palette.accOrange, preset: preset)
        }

        return readableAccentToken(palette.accRed, preset: preset)
    }

    static func resetEmphasisToken(
        forRemainingPercent remainingPercent: Int?,
        preset: CodexThemePreset = activePreset
    ) -> CodexColorToken {
        let palette = palette(for: preset)

        guard let remainingPercent else {
            return readableAccentToken(palette.accYellow, preset: preset)
        }

        switch clamped(remainingPercent) {
        case 0..<25:
            return readableAccentToken(palette.accRed, preset: preset)
        case 25..<50:
            return readableAccentToken(palette.accOrange, preset: preset)
        default:
            return readableAccentToken(palette.accYellow, preset: preset)
        }
    }

    static func resetCountdownEmphasisToken(preset: CodexThemePreset = activePreset) -> CodexColorToken {
        readableAccentToken(palette(for: preset).accBlue, preset: preset)
    }

    static var resetCountdownEmphasisColor: Color {
        resetCountdownEmphasisToken().color
    }

    static func statusLabelColor(for authState: AuthState, limitReached: Bool) -> Color {
        if authState == .signedIn, limitReached == false {
            return .primary
        }

        if authState == .signingIn {
            return .primary
        }

        return statusTone(for: authState, limitReached: limitReached).foregroundColor
    }

    static func interPostScriptName(for weight: Font.Weight) -> String {
        if weight == .medium {
            return "Inter-Medium"
        }

        if weight == .semibold || weight == .bold || weight == .heavy || weight == .black {
            return "Inter-SemiBold"
        }

        return "Inter-Regular"
    }

    static func utilityFont(size: CGFloat, weight: Font.Weight) -> Font {
        if let font = NSFont(name: interPostScriptName(for: weight), size: size) {
            return Font(font)
        }

        if let fallback = NSFontManager.shared.font(
            withFamily: "Inter",
            traits: [],
            weight: appKitWeight(for: weight),
            size: size
        ) {
            return Font(fallback)
        }

        return .system(size: size, weight: weight)
    }

    static func sansFont(size: CGFloat, weight: Font.Weight) -> Font {
        if let font = NSFontManager.shared.font(
            withFamily: "Manrope",
            traits: [],
            weight: appKitWeight(for: weight),
            size: size
        ) {
            return Font(font)
        }

        return .system(size: size, weight: weight)
    }

    static func displayFont(size: CGFloat, weight: Font.Weight, italic: Bool) -> Font {
        let traits: NSFontTraitMask = italic ? [.italicFontMask] : []
        if let font = NSFontManager.shared.font(
            withFamily: "Cormorant Garamond",
            traits: traits,
            weight: appKitWeight(for: weight),
            size: size
        ) {
            return Font(font)
        }

        let fallback = Font.system(size: size, weight: weight, design: .serif)
        return italic ? fallback.italic() : fallback
    }

    static func canvasDarkeningOverlay() -> LinearGradient {
        canvasDarkeningOverlay(preset: activePreset)
    }

    static func canvasDarkeningOverlay(preset: CodexThemePreset) -> LinearGradient {
        if palette(for: preset).isDark {
            return LinearGradient(
                colors: [.black.opacity(0.22), .clear, .black.opacity(0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        return LinearGradient(
            colors: [Color.white.opacity(0.18), .clear, Color.black.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func appKitWeight(for weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight:
            return 2
        case .thin:
            return 3
        case .light:
            return 4
        case .regular:
            return 5
        case .medium:
            return 6
        case .semibold:
            return 8
        case .bold:
            return 9
        case .heavy:
            return 10
        case .black:
            return 11
        default:
            return 5
        }
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private static func readableAccentBackgroundTokens(for preset: CodexThemePreset) -> [CodexColorToken] {
        [
            canvasFillToken(for: preset),
            shellFillToken(for: preset),
            surfaceToken(for: .regular, preset: preset),
            surfaceToken(for: .nested, preset: preset),
            surfaceToken(for: .strong, preset: preset),
            surfaceToken(for: .subtle, preset: preset),
            cardFillToken(for: .regular, preset: preset),
        ]
    }

    fileprivate static func contrastRatio(_ foreground: CodexColorToken, _ background: CodexColorToken) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ token: CodexColorToken) -> Double {
        let rgb = rgbComponents(token)
        return (0.2126 * linearSRGB(rgb.red))
            + (0.7152 * linearSRGB(rgb.green))
            + (0.0722 * linearSRGB(rgb.blue))
    }

    private static func linearSRGB(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func rgbComponents(_ token: CodexColorToken) -> (red: Double, green: Double, blue: Double) {
        let hex = token.hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = Int(hex, radix: 16) ?? 0
        return (
            Double((value >> 16) & 0xFF) / 255.0,
            Double((value >> 8) & 0xFF) / 255.0,
            Double(value & 0xFF) / 255.0
        )
    }
}

private extension CodexColorToken {
    func passesContrast(_ minimumRatio: Double, against backgrounds: [CodexColorToken]) -> Bool {
        backgrounds.allSatisfy { background in
            CodexTheme.contrastRatio(self, background) >= minimumRatio
        }
    }
}

enum CodexFontRegistry {
    static func registerBundledFonts() {
        guard let fontsDirectory = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              let enumerator = FileManager.default.enumerator(
                at: fontsDirectory,
                includingPropertiesForKeys: nil
              ) else {
            return
        }

        for case let fileURL as URL in enumerator where ["ttf", "otf"].contains(fileURL.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil)
        }
    }
}

extension Font {
    static func codexSans(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo _: Font.TextStyle = .body
    ) -> Font {
        CodexTheme.sansFont(size: size, weight: weight)
    }

    static func codexUtility(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo _: Font.TextStyle = .body
    ) -> Font {
        CodexTheme.utilityFont(size: size, weight: weight)
    }

    static func codexDisplay(
        size: CGFloat,
        weight: Font.Weight = .semibold,
        italic: Bool = false
    ) -> Font {
        CodexTheme.displayFont(size: size, weight: weight, italic: italic)
    }

    static let codexDisplayTitle = Font.codexDisplay(size: 34, weight: .semibold, italic: true)
    static let codexDisplaySubtitle = Font.codexDisplay(size: 22, weight: .medium, italic: true)
    static let codexTitle = Font.codexSans(size: 18, weight: .semibold, relativeTo: .headline)
    static let codexBody = Font.codexSans(size: 15, weight: .regular, relativeTo: .body)
    static let codexBodyStrong = Font.codexSans(size: 15, weight: .semibold, relativeTo: .body)
    static let codexSmall = Font.codexSans(size: 13, weight: .regular, relativeTo: .subheadline)
    static let codexSmallStrong = Font.codexSans(size: 13, weight: .semibold, relativeTo: .subheadline)
    static let codexCaption = Font.codexUtility(size: 12, weight: .medium, relativeTo: .caption)
    static let codexMetric = Font.codexUtility(size: 14, weight: .semibold, relativeTo: .subheadline)
    static let codexMicro = Font.codexUtility(size: 11, weight: .medium, relativeTo: .caption2)
    static let codexLargeMetric = Font.codexSans(size: 26, weight: .semibold, relativeTo: .title2)
    static let codexMenuBarLabel = Font.codexUtility(size: 12, weight: .semibold, relativeTo: .caption)
}

extension Color {
    init(hex: String, alpha: Double = 1) {
        let hex = hex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }

    func mixed(with other: Color, fraction: Double) -> Color {
        let lhs = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.black
        let rhs = NSColor(other).usingColorSpace(.deviceRGB) ?? NSColor.black
        let clampedFraction = max(0, min(fraction, 1))

        return Color(
            .sRGB,
            red: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * clampedFraction,
            green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * clampedFraction,
            blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * clampedFraction,
            opacity: lhs.alphaComponent + (rhs.alphaComponent - lhs.alphaComponent) * clampedFraction
        )
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.black
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

private struct CodexThemeRefreshModifier: ViewModifier {
    @AppStorage(CodexThemeSettings.Keys.appearanceMode) private var appearanceMode = CodexThemeSettings.defaultAppearanceMode
    @AppStorage(CodexThemeSettings.Keys.contrast) private var contrast = CodexThemeSettings.defaultContrast

    private var refreshContext: CodexThemeRefreshContext {
        CodexThemeRefreshContext(appearanceMode: appearanceMode, contrast: contrast)
    }

    func body(content: Content) -> some View {
        let context = refreshContext

        content
            .environment(\.codexThemeRefreshContext, context)
            .preferredColorScheme(context.preferredColorScheme)
    }
}

extension EnvironmentValues {
    @Entry var codexThemeRefreshContext = CodexThemeRefreshContext()
}

extension View {
    func codexThemeRefreshScope() -> some View {
        modifier(CodexThemeRefreshModifier())
    }
}

struct CodexBackdrop: View {
    @AppStorage(CodexThemeSettings.Keys.appearanceMode) private var appearanceMode = CodexThemeSettings.defaultAppearanceMode
    @AppStorage(CodexThemeSettings.Keys.contrast) private var contrast = CodexThemeSettings.defaultContrast

    private var themeContext: CodexThemeRefreshContext {
        CodexThemeRefreshContext(appearanceMode: appearanceMode, contrast: contrast)
    }

    var body: some View {
        let palette = CodexTheme.palette(for: themeContext.preset)

        ZStack {
            CodexTheme.canvasFillToken(for: themeContext.preset).color

            LinearGradient(
                colors: [
                    palette.bg1.color(alpha: palette.isDark ? 0.30 : 0.64),
                    .clear,
                    palette.isDark ? Color.black.opacity(0.20) : palette.bg2.color(alpha: 0.50),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            CodexTheme.canvasDarkeningOverlay(preset: themeContext.preset)
        }
        .ignoresSafeArea()
    }
}

struct CodexShell<Content: View>: View {
    @AppStorage(CodexThemeSettings.Keys.appearanceMode) private var appearanceMode = CodexThemeSettings.defaultAppearanceMode
    @AppStorage(CodexThemeSettings.Keys.contrast) private var contrast = CodexThemeSettings.defaultContrast

    let role: CodexSurfaceRole
    let padding: CGFloat
    let content: Content

    init(
        role: CodexSurfaceRole = .panel,
        padding: CGFloat = CodexTheme.chromePadding,
        @ViewBuilder content: () -> Content
    ) {
        self.role = role
        self.padding = padding
        self.content = content()
    }

    private var themeContext: CodexThemeRefreshContext {
        CodexThemeRefreshContext(appearanceMode: appearanceMode, contrast: contrast)
    }

    var body: some View {
        let shadow = CodexTheme.shadow(for: .strong, preset: themeContext.preset)
        let shellShape = RoundedRectangle(
            cornerRadius: CodexTheme.shellCornerRadius,
            style: .continuous
        )

        ZStack {
            CodexBackdrop()

            shellShape
                .fill(shellFill(for: role))
                .overlay(
                    shellShape
                        .fill(CodexTheme.surfaceSheen(for: .strong, preset: themeContext.preset))
                )
                .overlay(
                    shellShape
                        .stroke(CodexTheme.surfaceBorder(for: .strong, preset: themeContext.preset), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    GeometryReader { proxy in
                        content
                            .frame(
                                width: max(proxy.size.width - (padding * 2), 0),
                                height: max(proxy.size.height - (padding * 2), 0),
                                alignment: .topLeading
                            )
                            .offset(x: padding, y: padding)
                    }
                }
                .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
        }
        .environment(\.codexThemeRefreshContext, themeContext)
        .preferredColorScheme(themeContext.preferredColorScheme)
    }

    private func shellFill(for role: CodexSurfaceRole) -> Color {
        switch role {
        case .panel:
            return CodexTheme.shellFillToken(for: themeContext.preset).color
        case .dialog:
            return CodexTheme.shellFillToken(for: themeContext.preset).color
        }
    }
}

struct CodexCard<Content: View>: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext

    let tier: CodexSurfaceTier
    let accent: Color?
    let padding: CGFloat
    let shadow: Bool
    let content: Content

    init(
        tier: CodexSurfaceTier = .regular,
        accent: Color? = nil,
        padding: CGFloat = CodexTheme.panelPadding,
        shadow: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.tier = tier
        self.accent = accent
        self.padding = padding
        self.shadow = shadow
        self.content = content()
    }

    var body: some View {
        let shadowStyle = CodexTheme.shadow(for: tier, preset: themeContext.preset)
        let cornerRadius = CodexTheme.cornerRadius(for: tier)

        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(CodexTheme.cardFillToken(for: tier, preset: themeContext.preset).color)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(CodexTheme.surfaceSheen(for: tier, preset: themeContext.preset))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                CodexTheme.surfaceBorder(
                                    for: tier,
                                    preset: themeContext.preset,
                                    accent: accent
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: shadow ? shadowStyle.color : .clear,
                        radius: shadow ? shadowStyle.radius : 0,
                        y: shadow ? shadowStyle.y : 0
                    )
            )
    }
}

struct CodexStatusBadge: View {
    let title: String
    let tone: CodexStatusTone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.accentColor)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.codexCaption)
                .foregroundStyle(tone.foregroundColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                        .fill(tone.backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                        .stroke(tone.borderColor, lineWidth: 1)
                )
        )
    }
}

struct CodexStatusBanner: View {
    let title: String
    let message: String
    let tone: CodexStatusTone
    let symbolName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                            .stroke(tone.borderColor, lineWidth: 1)
                    )

                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone.accentColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: CodexTheme.Spacing.micro) {
                Text(title)
                    .font(.codexSmallStrong)
                    .foregroundStyle(CodexTheme.headingText)

                Text(message)
                    .font(.codexSmall)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(CodexTheme.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .nested))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                        .fill(tone.backgroundColor.opacity(0.52))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                        .stroke(tone.borderColor, lineWidth: 1)
                )
        )
    }
}

struct CodexProgressBar: View {
    let remainingPercent: Int

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(remainingPercent, 0), 100)
            let width = proxy.size.width * CGFloat(clamped) / 100

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: CodexTheme.thinBarCornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.thinBarCornerRadius, style: .continuous)
                            .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: CodexTheme.thinBarCornerRadius, style: .continuous)
                    .fill(CodexTheme.progressGradient(forRemainingPercent: clamped))
                    .frame(width: max(width, 10))
            }
        }
        .frame(height: 8)
    }
}

struct CodexIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let tone: CodexControlTone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexSmallStrong)
            .foregroundStyle(foregroundColor)
            .frame(width: 36, height: 36)
            .background(backgroundShape(configuration: configuration))
            .overlay(borderShape)
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowYOffset)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return CodexTheme.disabledText
        }

        switch tone {
        case .primary:
            return CodexTheme.accentInk
        case .secondary:
            return CodexTheme.utilityActionText
        case .danger:
            return CodexTheme.dangerText
        case .quiet:
            return CodexTheme.mutedText
        }
    }

    @ViewBuilder
    private func backgroundShape(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: CodexTheme.iconCornerRadius, style: .continuous)

        if isEnabled == false {
            shape
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    shape
                        .fill(CodexTheme.surfaceSheen(for: .subtle))
                )
        } else {
            switch tone {
            case .primary:
                shape
                    .fill(CodexTheme.accentGradient)
                    .overlay(
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.08), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            case .secondary, .danger, .quiet:
                shape
                    .fill(fillColor(isPressed: configuration.isPressed))
                    .overlay(
                        shape
                            .fill(CodexTheme.surfaceSheen(for: .subtle))
                    )
            }
        }
    }

    private var borderShape: some View {
        RoundedRectangle(cornerRadius: CodexTheme.iconCornerRadius, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
        guard isEnabled else {
            return CodexTheme.surfaceBorder(for: .subtle)
        }

        switch tone {
        case .primary:
            return Color.white.opacity(0.08)
        case .secondary:
            return CodexTheme.surfaceBorder(for: .subtle)
        case .danger:
            return CodexTheme.accentRed.opacity(0.28)
        case .quiet:
            return CodexTheme.surfaceBorder(for: .subtle).opacity(0.86)
        }
    }

    private func fillColor(isPressed: Bool) -> Color {
        switch tone {
        case .primary:
            return isPressed ? CodexTheme.accentRed.opacity(0.92) : .clear
        case .secondary:
            return CodexTheme.surfaceFill(for: .subtle)
        case .danger:
            return CodexTheme.accentRed.opacity(isPressed ? 0.18 : 0.12)
        case .quiet:
            return CodexTheme.surfaceFill(for: .subtle).opacity(isPressed ? 0.98 : 0.82)
        }
    }

    private var shadowColor: Color {
        guard isEnabled else {
            return .clear
        }

        switch tone {
        case .primary:
            return CodexTheme.accentOrange.opacity(0.24)
        default:
            return .black.opacity(0.16)
        }
    }

    private var shadowRadius: CGFloat {
        tone == .primary ? 12 : 8
    }

    private var shadowYOffset: CGFloat {
        tone == .primary ? 6 : 4
    }
}

struct CodexIconButton: View {
    let symbolName: String
    let helpText: String
    let tone: CodexControlTone
    let isDisabled: Bool
    let action: () -> Void

    init(
        symbolName: String,
        helpText: String,
        tone: CodexControlTone,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.helpText = helpText
        self.tone = tone
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(CodexIconButtonStyle(tone: tone))
        .accessibilityLabel(helpText)
        .help(helpText)
        .disabled(isDisabled)
    }
}

struct CodexPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexSmallStrong)
            .foregroundStyle(isEnabled ? CodexTheme.accentInk : CodexTheme.disabledText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        isEnabled
                            ? AnyShapeStyle(CodexTheme.accentGradient)
                            : AnyShapeStyle(CodexTheme.surfaceFill(for: .subtle))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .stroke(
                                isEnabled
                                    ? Color.white.opacity(0.08)
                                    : CodexTheme.surfaceBorder(for: .subtle),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: isEnabled ? CodexTheme.accentOrange.opacity(0.20) : .clear, radius: 12, y: 6)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CodexSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexSmallStrong)
            .foregroundStyle(isEnabled ? CodexTheme.actionText : CodexTheme.disabledText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .fill(CodexTheme.surfaceSheen(for: .subtle))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
            )
            .shadow(color: isEnabled ? .black.opacity(0.16) : .clear, radius: 8, y: 4)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CodexQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexCaption)
            .foregroundStyle(isEnabled ? CodexTheme.mutedText : CodexTheme.disabledText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle).opacity(configuration.isPressed ? 0.98 : 0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
            )
    }
}

struct CodexDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexSmallStrong)
            .foregroundStyle(isEnabled ? CodexTheme.dangerText : CodexTheme.disabledText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        isEnabled
                            ? CodexTheme.accentRed.opacity(configuration.isPressed ? 0.16 : 0.10)
                            : CodexTheme.surfaceFill(for: .subtle)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(
                        isEnabled
                            ? CodexTheme.accentRed.opacity(0.24)
                            : CodexTheme.surfaceBorder(for: .subtle),
                        lineWidth: 1
                    )
            )
    }
}
