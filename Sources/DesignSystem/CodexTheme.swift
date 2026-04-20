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
        switch self {
        case .neutral:
            CodexTheme.Palette.gray1
        case .info:
            CodexTheme.Palette.accYellow
        case .success:
            CodexTheme.Palette.accGreen
        case .warning:
            CodexTheme.Palette.accOrange
        case .critical:
            CodexTheme.Palette.accRed
        }
    }

    var foregroundColor: Color {
        switch self {
        case .neutral:
            CodexTheme.primaryText
        default:
            accentToken.color
        }
    }

    var backgroundColor: Color {
        accentToken.color(alpha: 0.14)
    }

    var borderColor: Color {
        accentToken.color(alpha: 0.34)
    }
}

enum CodexControlTone: Sendable {
    case primary
    case secondary
    case danger
    case quiet
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
        static let accGreen = CodexColorToken(hex: "#83C092")
        static let accAqua = CodexColorToken(hex: "#7FBBB3")
        static let accPink = CodexColorToken(hex: "#D699B6")
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

    static let bg0 = Palette.bg0.color
    static let bg1 = Palette.bg1.color
    static let bg2 = Palette.bg2.color
    static let bg3 = Palette.bg3.color
    static let bg4 = Palette.bg4.color
    static let primaryText = Palette.fg.color
    static let mutedText = Palette.gray0.color
    static let quietText = Palette.gray1.color
    static let supportText = Palette.gray2.color
    static let accentOrange = Palette.accOrange.color
    static let accentRed = Palette.accRed.color
    static let accentYellow = Palette.accYellow.color
    static let accentGreen = Palette.accGreen.color
    static let accentAqua = Palette.accAqua.color
    static let accentPink = Palette.accPink.color
    static let accentInk = bg0

    static let shellCornerRadius = Radius.strongSurface
    static let sectionCornerRadius = Radius.surface
    static let fieldCornerRadius = Radius.field
    static let controlCornerRadius = Radius.button
    static let iconCornerRadius = Radius.icon
    static let thinBarCornerRadius = Radius.progress

    static let panelPadding = Spacing.panel
    static let sectionSpacing = Spacing.section
    static let rowSpacing = Spacing.row
    static let contentSpacing = Spacing.content
    static let chromePadding = Spacing.outerPage

    static let surfaceLine = Palette.bg6.color(alpha: 0.55)
    static let border = surfaceLine
    static let warmBorder = accentOrange.opacity(0.28)
    static let focusRing = accentOrange.opacity(0.38)
    static let shadowPrimary = Color.black.opacity(0.34)
    static let primaryActionTokens = [Palette.accOrange, Palette.accRed]

    static let accentGradient = LinearGradient(
        colors: primaryActionTokens.map(\.color),
        startPoint: .leading,
        endPoint: .trailing
    )

    static let warmGradient = LinearGradient(
        colors: [accentOrange, accentRed],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let shellFill = surfaceFill(for: .regular)
    static let shellDialogFill = Palette.bg1.color(alpha: 0.95)
    static let shellMutedFill = surfaceFill(for: .subtle)
    static let sectionFill = surfaceFill(for: .regular)
    static let sectionMutedFill = surfaceFill(for: .nested)

    static func shellFill(for role: CodexSurfaceRole) -> Color {
        switch role {
        case .panel:
            shellFill
        case .dialog:
            shellDialogFill
        }
    }

    static func surfaceFill(for tier: CodexSurfaceTier) -> Color {
        switch tier {
        case .strong:
            return Palette.bg4.color(alpha: 0.88)
        case .regular:
            return Palette.bg1.color(alpha: 0.84)
        case .nested:
            return Palette.bg2.color(alpha: 0.82)
        case .subtle:
            return Palette.bg0.color
                .mixed(with: Palette.bg2.color, fraction: 0.46)
                .opacity(0.92)
        }
    }

    static func surfaceBorder(for tier: CodexSurfaceTier, accent: Color? = nil) -> Color {
        if let accent {
            return accent.opacity(tier == .strong ? 0.36 : 0.28)
        }

        switch tier {
        case .strong:
            return Palette.bg6.color(alpha: 0.62)
        case .regular:
            return Palette.bg6.color(alpha: 0.55)
        case .nested:
            return Palette.bg5.color(alpha: 0.44)
        case .subtle:
            return Palette.bg5.color(alpha: 0.38)
        }
    }

    static func surfaceSheen(for tier: CodexSurfaceTier) -> LinearGradient {
        switch tier {
        case .strong:
            return LinearGradient(
                colors: [Color.white.opacity(0.07), Color.white.opacity(0.02), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        case .regular:
            return LinearGradient(
                colors: [Color.white.opacity(0.055), Color.white.opacity(0.018), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        case .nested:
            return LinearGradient(
                colors: [Color.white.opacity(0.035), Color.white.opacity(0.012), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        case .subtle:
            return LinearGradient(
                colors: [Color.white.opacity(0.025), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    static func shadow(for tier: CodexSurfaceTier) -> CodexShadowStyle {
        switch tier {
        case .strong:
            return CodexShadowStyle(color: .black.opacity(0.30), radius: 18, y: 10)
        case .regular:
            return CodexShadowStyle(color: .black.opacity(0.24), radius: 14, y: 8)
        case .nested:
            return CodexShadowStyle(color: .black.opacity(0.18), radius: 10, y: 5)
        case .subtle:
            return CodexShadowStyle(color: .black.opacity(0.12), radius: 6, y: 3)
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

    static func progressTextToken(forRemainingPercent remainingPercent: Int) -> CodexColorToken {
        switch clamped(remainingPercent) {
        case 0..<25:
            Palette.accRed
        case 25..<50:
            Palette.accOrange
        case 50..<75:
            Palette.accYellow
        default:
            Palette.accGreen
        }
    }

    static func usagePercentageColor(forRemainingPercent remainingPercent: Int) -> Color {
        progressTextToken(forRemainingPercent: remainingPercent).color
    }

    static func progressStopTokens(forRemainingPercent remainingPercent: Int) -> [CodexColorToken] {
        let dominant = progressTextToken(forRemainingPercent: remainingPercent)
        return [
            Palette.accRed.mixed(with: dominant, fraction: 0.20),
            Palette.accOrange.mixed(with: dominant, fraction: 0.24),
            Palette.accYellow.mixed(with: dominant, fraction: 0.22),
            Palette.accGreen.mixed(with: dominant, fraction: 0.18),
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

    static func expiryEmphasisToken(for date: Date?, referenceDate: Date = .now) -> CodexColorToken? {
        guard let date else {
            return nil
        }

        let remainingSeconds = Int(date.timeIntervalSince(referenceDate).rounded(.down))
        let criticalThresholdSeconds = 3 * 24 * 3_600
        let warningThresholdSeconds = 7 * 24 * 3_600

        if remainingSeconds <= 0 {
            return Palette.accRed
        }

        if remainingSeconds >= warningThresholdSeconds {
            return Palette.accYellow
        }

        if remainingSeconds >= criticalThresholdSeconds {
            return Palette.accOrange
        }

        return Palette.accRed
    }

    static func resetEmphasisToken(forRemainingPercent remainingPercent: Int?) -> CodexColorToken {
        guard let remainingPercent else {
            return Palette.accYellow
        }

        switch clamped(remainingPercent) {
        case 0..<25:
            return Palette.accRed
        case 25..<50:
            return Palette.accOrange
        default:
            return Palette.accYellow
        }
    }

    static func resetCountdownEmphasisToken() -> CodexColorToken {
        Palette.accAqua
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
        LinearGradient(
            colors: [.black.opacity(0.18), .clear, .black.opacity(0.26)],
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

struct CodexBackdrop: View {
    var body: some View {
        ZStack {
            CodexTheme.bg0

            LinearGradient(
                colors: [
                    CodexTheme.Palette.bg0.color,
                    CodexTheme.Palette.bg1.color(alpha: 0.97),
                    CodexTheme.Palette.bg0.color,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            CodexTheme.canvasDarkeningOverlay()

            Circle()
                .fill(CodexTheme.accentOrange.opacity(0.14))
                .frame(width: 480, height: 480)
                .blur(radius: 150)
                .offset(x: -220, y: -260)

            Circle()
                .fill(CodexTheme.accentRed.opacity(0.12))
                .frame(width: 520, height: 520)
                .blur(radius: 180)
                .offset(x: 240, y: -180)

            Circle()
                .fill(CodexTheme.accentYellow.opacity(0.10))
                .frame(width: 560, height: 560)
                .blur(radius: 220)
                .offset(x: 30, y: 280)
        }
        .ignoresSafeArea()
    }
}

struct CodexShell<Content: View>: View {
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

    var body: some View {
        let shadow = CodexTheme.shadow(for: .strong)
        let shellShape = RoundedRectangle(
            cornerRadius: CodexTheme.shellCornerRadius,
            style: .continuous
        )

        ZStack {
            CodexBackdrop()

            shellShape
                .fill(CodexTheme.shellFill(for: role))
                .overlay(
                    shellShape
                        .fill(CodexTheme.surfaceSheen(for: .strong))
                )
                .overlay(
                    shellShape
                        .stroke(CodexTheme.surfaceBorder(for: .strong), lineWidth: 1)
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
        .preferredColorScheme(.dark)
    }
}

struct CodexCard<Content: View>: View {
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
        let shadowStyle = CodexTheme.shadow(for: tier)
        let cornerRadius = CodexTheme.cornerRadius(for: tier)

        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: tier))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(CodexTheme.surfaceSheen(for: tier))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(CodexTheme.surfaceBorder(for: tier, accent: accent), lineWidth: 1)
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
                .fill(tone.foregroundColor)
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
                    .foregroundStyle(tone.foregroundColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: CodexTheme.Spacing.micro) {
                Text(title)
                    .font(.codexSmallStrong)
                    .foregroundStyle(CodexTheme.primaryText)

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
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.46)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch tone {
        case .primary:
            return CodexTheme.accentInk
        case .secondary:
            return CodexTheme.primaryText
        case .danger:
            return CodexTheme.accentRed
        case .quiet:
            return CodexTheme.mutedText
        }
    }

    @ViewBuilder
    private func backgroundShape(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: CodexTheme.iconCornerRadius, style: .continuous)

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

    private var borderShape: some View {
        RoundedRectangle(cornerRadius: CodexTheme.iconCornerRadius, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
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
            .foregroundStyle(CodexTheme.accentInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.accentGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .shadow(color: CodexTheme.accentOrange.opacity(0.20), radius: 12, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.46)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CodexSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexSmallStrong)
            .foregroundStyle(CodexTheme.primaryText)
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
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.46)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CodexQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexCaption)
            .foregroundStyle(CodexTheme.mutedText)
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
            .opacity(isEnabled ? 1 : 0.46)
    }
}

struct CodexDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.codexSmallStrong)
            .foregroundStyle(CodexTheme.accentRed)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.accentRed.opacity(configuration.isPressed ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(CodexTheme.accentRed.opacity(0.24), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.46)
    }
}
