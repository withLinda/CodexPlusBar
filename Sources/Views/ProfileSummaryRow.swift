import SwiftUI

enum ProfileSummaryRowMode: Equatable, Sendable {
    case sidebar(isSelected: Bool)
    case menuBar(isPinned: Bool)
}

enum ProfileSummaryRowAccessory: Equatable, Sendable {
    case none
    case refreshing
    case pinned
    case pinnedAndRefreshing
}

enum ProfileSummaryRowSupportStyle: Equatable, Sendable {
    case muted
    case emphasized(CodexStatusTone)

    var foregroundStyle: Color {
        switch self {
        case .muted:
            return CodexTheme.mutedText
        case let .emphasized(tone):
            return tone.foregroundColor
        }
    }
}

struct ProfileSummaryRowPresentation: Equatable, Sendable {
    let provider: ProfileProvider
    let title: String
    let tags: [PlusProfileTag]
    let usageSummary: ProfileUsageSummary?
    let supportText: String
    let supportStyle: ProfileSummaryRowSupportStyle
    let expiryValue: DisplayFormatter.LabeledValue?
    let expiryEmphasisToken: CodexColorToken?
    let accessory: ProfileSummaryRowAccessory
    let isPinned: Bool
    let compactTagSummary: ProfileTagSummary
    let showsStatusBadge: Bool
    let showsInlineSecondaryActions: Bool
    let canOpenEmailLink: Bool
    let showsPinAction: Bool
    let pinActionSymbolName: String
    let pinActionAccessibilityLabel: String
    let searchPhoneNumber: String?

    init(
        snapshot: PlusProfileSnapshot,
        referenceDate: Date = .now,
        mode: ProfileSummaryRowMode,
        searchPhoneNumber: String? = nil
    ) {
        provider = snapshot.profile.provider
        title = DisplayFormatter.privateProfileLabel(snapshot.label)
        tags = snapshot.tags
        compactTagSummary = ProfileTagSummary(tags: snapshot.tags)
        let trimmedSearchPhoneNumber = searchPhoneNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchPhoneNumber = if let trimmedSearchPhoneNumber,
                                    trimmedSearchPhoneNumber.isEmpty == false {
            trimmedSearchPhoneNumber
        } else {
            nil
        }
        let usageSummary = snapshot.usageSummary(referenceDate: referenceDate)
        self.usageSummary = usageSummary
        let showsExpirySupportLine = usageSummary != nil

        if showsExpirySupportLine {
            expiryValue = DisplayFormatter.expiryValue(
                snapshot.expiresAt,
                referenceDate: referenceDate
            )
            expiryEmphasisToken = CodexTheme.expiryEmphasisToken(
                for: snapshot.expiresAt,
                referenceDate: referenceDate
            )
        } else {
            expiryValue = nil
            expiryEmphasisToken = nil
        }

        if usageSummary != nil {
            supportText = snapshot.note ?? snapshot.state.title
            supportStyle = .muted
        } else {
            let fallbackMessage: String
            switch snapshot.state {
            case .idle:
                fallbackMessage = "Open the manager to sign in or refresh this profile."
            case .loading:
                fallbackMessage = "Loading live usage."
            case .ready:
                fallbackMessage = snapshot.note ?? "Live usage is ready."
            case .needsLogin:
                fallbackMessage = "Sign in again in the manager window."
            case .failed:
                fallbackMessage = "Refresh this profile in the manager window."
            }

            supportText = snapshot.statusMessage ?? fallbackMessage
            supportStyle = snapshot.state == .ready ? .muted : .emphasized(snapshot.state.tone)
        }

        switch mode {
        case .sidebar:
            isPinned = false
            accessory = snapshot.isRefreshing ? .refreshing : .none
            showsInlineSecondaryActions = false
            canOpenEmailLink = false
            showsPinAction = false
            pinActionSymbolName = ""
            pinActionAccessibilityLabel = ""
        case let .menuBar(isPinned):
            self.isPinned = isPinned
            switch snapshot.isRefreshing {
            case true:
                accessory = .refreshing
            case false:
                accessory = .none
            }

            showsInlineSecondaryActions = true
            canOpenEmailLink = snapshot.profile.resolvedEmailLinkURL != nil
            showsPinAction = true
            pinActionSymbolName = isPinned ? "pin.circle.fill" : "pin.circle"
            pinActionAccessibilityLabel = isPinned ? "On top" : "Show on top"
        }

        showsStatusBadge = false
    }

    var showsTags: Bool {
        tags.isEmpty == false
    }
}

struct ProfileSummaryRow: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    let presentation: ProfileSummaryRowPresentation
    let mode: ProfileSummaryRowMode
    let textScale: Double
    let primaryAction: (() -> Void)?
    let copyAction: (() -> Void)?
    let emailAction: (() -> Void)?
    let pinAction: (() -> Void)?
    let switchAction: (() -> Void)?
    let openChamberSwitchAction: (() -> Void)?

    init(
        snapshot: PlusProfileSnapshot,
        referenceDate: Date = .now,
        mode: ProfileSummaryRowMode,
        textScale: Double = 1,
        searchPhoneNumber: String? = nil,
        primaryAction: (() -> Void)? = nil,
        copyAction: (() -> Void)? = nil,
        emailAction: (() -> Void)? = nil,
        pinAction: (() -> Void)? = nil,
        switchAction: (() -> Void)? = nil,
        openChamberSwitchAction: (() -> Void)? = nil
    ) {
        self.init(
            presentation: ProfileSummaryRowPresentation(
                snapshot: snapshot,
                referenceDate: referenceDate,
                mode: mode,
                searchPhoneNumber: searchPhoneNumber
            ),
            mode: mode,
            textScale: textScale,
            primaryAction: primaryAction,
            copyAction: copyAction,
            emailAction: emailAction,
            pinAction: pinAction,
            switchAction: switchAction,
            openChamberSwitchAction: openChamberSwitchAction
        )
    }

    init(
        presentation: ProfileSummaryRowPresentation,
        mode: ProfileSummaryRowMode,
        textScale: Double = 1,
        primaryAction: (() -> Void)? = nil,
        copyAction: (() -> Void)? = nil,
        emailAction: (() -> Void)? = nil,
        pinAction: (() -> Void)? = nil,
        switchAction: (() -> Void)? = nil,
        openChamberSwitchAction: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.mode = mode
        self.textScale = textScale
        self.primaryAction = primaryAction
        self.copyAction = copyAction
        self.emailAction = emailAction
        self.pinAction = pinAction
        self.switchAction = switchAction
        self.openChamberSwitchAction = openChamberSwitchAction
    }

    var body: some View {
        Group {
            if isMenuBarMode {
                menuBarContent
            } else {
                sidebarContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, scaled(8))
        .background(backgroundShape)
        .onHover { isHovered = $0 }
    }

    private var isMenuBarMode: Bool {
        if case .menuBar = mode {
            return true
        }

        return false
    }

    private var effectiveTextScale: Double {
        isMenuBarMode ? MenuBarPanelTextScalePreference.normalizedTextScale(textScale) : 1
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * CGFloat(effectiveTextScale)
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            wrappedPrimaryAction {
                sidebarContentBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sidebarContentBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow

            if let searchPhoneNumber = presentation.searchPhoneNumber {
                phoneSearchContextLine(searchPhoneNumber)
            }

            if let usageSummary = presentation.usageSummary {
                usageSummaryView(usageSummary, spacing: 8)
            }

            metadataLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuBarContent: some View {
        VStack(alignment: .leading, spacing: scaled(7)) {
            HStack(alignment: .center, spacing: scaled(5)) {
                wrappedPrimaryAction {
                    menuBarTitleLabel
                }
                .layoutPriority(1)

                if presentation.accessory != .none {
                    accessoryView
                }

                Spacer(minLength: 0)

                if presentation.showsInlineSecondaryActions {
                    topActionRail
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            wrappedPrimaryAction {
                VStack(alignment: .leading, spacing: scaled(8)) {
                    if let searchPhoneNumber = presentation.searchPhoneNumber {
                        phoneSearchContextLine(searchPhoneNumber)
                    }

                    if let usageSummary = presentation.usageSummary {
                        usageSummaryView(usageSummary, spacing: scaled(6))
                    }

                    metadataLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProfileProviderBadge(provider: presentation.provider, showsText: false)

                Text(presentation.title)
                    .font(ProfileManagerTypography.smallStrong)
                    .foregroundStyle(CodexTheme.dataValueText)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .truncationMode(.middle)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if case .sidebar(isSelected: true) = mode {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CodexTheme.dataValueText)
                    .accessibilityLabel("Selected profile")
            }

            if presentation.accessory != .none {
                accessoryView
            }
        }
    }

    private var menuBarTitleLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: scaled(6)) {
            ProfileProviderBadge(
                provider: presentation.provider,
                textScale: effectiveTextScale,
                showsText: false
            )

            Text(presentation.title)
                .font(ProfileManagerTypography.smallStrong(scale: effectiveTextScale))
                .foregroundStyle(CodexTheme.dataValueText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 40, alignment: .leading)
        }
    }

    private func phoneSearchContextLine(_ phoneNumber: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "phone")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CodexTheme.searchAction)
                .accessibilityHidden(true)

            Text(phoneNumber)
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.supportText)
                .lineLimit(1)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Phone number \(phoneNumber)")
    }

    private var topActionRail: some View {
        HStack(spacing: 4) {
            if presentation.provider == .codex {
                ProfileSummaryInlineIconButton(
                    symbolName: "arrow.triangle.2.circlepath",
                    label: "Switch and open ChatGPT",
                    helpText: "Switch to this account and reopen ChatGPT",
                    isDisabled: switchAction == nil,
                    action: switchAction ?? {}
                )

                ProfileSummaryInlineIconButton(
                    symbolName: "bubble.left.and.bubble.right",
                    label: "Switch OpenChamber OpenAI",
                    helpText: "Switch OpenChamber OpenAI · local instance. Save a sign-in in the manager first.",
                    isDisabled: openChamberSwitchAction == nil,
                    action: openChamberSwitchAction ?? {}
                )
            }

            if presentation.showsPinAction {
                ProfileSummaryInlineIconButton(
                    symbolName: presentation.pinActionSymbolName,
                    label: presentation.pinActionAccessibilityLabel,
                    helpText: presentation.isPinned
                        ? "This profile already drives the top menu bar summary."
                        : "Show this profile in the top menu bar summary.",
                    tone: presentation.isPinned ? .selected : .quiet,
                    isDisabled: presentation.isPinned || pinAction == nil,
                    action: pinAction ?? {}
                )
            }

            Menu {
                Button("Copy profile label", systemImage: "doc.on.doc", action: copyAction ?? {})
                    .disabled(copyAction == nil)
                Button("Open email link", systemImage: "arrow.up.forward.square", action: emailAction ?? {})
                    .disabled(!presentation.canOpenEmailLink || emailAction == nil)
                Divider()
                Button("Edit profile…", systemImage: "slider.horizontal.3", action: primaryAction ?? {})
                    .disabled(primaryAction == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(CodexTheme.utilityActionText)
            .accessibilityLabel("More actions for \(presentation.title)")
            .help("More profile actions")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metadataLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                supportLine
                Spacer(minLength: 0)
                if presentation.showsTags {
                    ProfileTagSummaryStrip(summary: presentation.compactTagSummary, textScale: effectiveTextScale)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                supportLine
                if presentation.showsTags {
                    ProfileTagSummaryStrip(summary: presentation.compactTagSummary, textScale: effectiveTextScale)
                }
            }
        }
    }

    private func usageSummaryView(_ usageSummary: ProfileUsageSummary, spacing: CGFloat) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            ProfileUsageMetricBlock(
                summary: usageSummary.primary,
                density: .compact,
                textScale: effectiveTextScale
            )

            ProfileUsageMetricBlock(
                summary: usageSummary.secondary,
                density: .compact,
                textScale: effectiveTextScale
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage summary")
        .accessibilityValue(usageSummary.accessibilityValue)
    }

    @ViewBuilder
    private var supportLine: some View {
        if let expiryValue = presentation.expiryValue {
            ProfileSummaryExpiryLine(
                presentation: expiryValue,
                emphasisToken: presentation.expiryEmphasisToken,
                textScale: effectiveTextScale
            )
        } else {
            Text(presentation.supportText)
                .font(ProfileManagerTypography.caption(scale: effectiveTextScale))
                .foregroundStyle(presentation.supportStyle.foregroundStyle)
                .lineLimit(2)
                .help(presentation.supportText)
        }
    }

    @ViewBuilder
    private func wrappedPrimaryAction<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let primaryAction {
            Button(action: primaryAction) {
                content()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        HStack(spacing: 6) {
            if isMenuBarMode == false,
               presentation.accessory == .pinned || presentation.accessory == .pinnedAndRefreshing {
                ProfileSummaryPinnedAccessory()
            }

            if presentation.accessory == .refreshing || presentation.accessory == .pinnedAndRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(CodexTheme.accentOrange)
            }
        }
    }

    private var backgroundShape: some View {
        let isSelected = if case let .sidebar(isSelected) = mode { isSelected } else { false }

        return RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
            .fill(
                CodexTheme.profileCardFillToken(
                    for: presentation.provider,
                    isSelected: isSelected,
                    preset: themeContext.preset
                ).color
            )
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                        .fill(CodexTheme.primaryText.opacity(0.035))
                }
                RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                    .stroke(
                        contrast == .increased && isSelected
                            ? CodexTheme.controlBoundary
                            : .clear,
                        lineWidth: 1
                    )
            }
    }
}

struct ProfileProviderBadge: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext

    let provider: ProfileProvider
    let textScale: Double
    let showsText: Bool

    init(
        provider: ProfileProvider,
        textScale: Double = 1,
        showsText: Bool = true
    ) {
        self.provider = provider
        self.textScale = textScale
        self.showsText = showsText
    }

    var body: some View {
        let accent = CodexTheme.profileProviderAccentToken(
            for: provider,
            preset: themeContext.preset
        ).color
        let selectedAccent = CodexTheme.profileProviderAccentToken(
            for: provider,
            isSelected: true,
            preset: themeContext.preset
        ).color

        HStack(spacing: 4 * CGFloat(textScale)) {
            Image(systemName: provider.systemImage)
                .font(.system(size: 9 * CGFloat(textScale), weight: .semibold))
                .accessibilityHidden(true)

            if showsText {
                Text(provider.displayName)
                    .lineLimit(1)
            }
        }
        .font(ProfileManagerTypography.micro(scale: textScale))
        .foregroundStyle(accent)
        .padding(.horizontal, showsText ? 6 * CGFloat(textScale) : 0)
        .padding(.vertical, showsText ? 4 * CGFloat(textScale) : 0)
        .background {
            if showsText {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        selectedAccent
                            .opacity(0.12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                selectedAccent.opacity(0.28),
                                lineWidth: 1
                            )
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) profile")
    }
}

private struct ProfileSummaryInlineIconButton: View {
    enum Tone {
        case quiet
        case accent
        case selected
    }

    let symbolName: String
    let label: String
    let helpText: String
    let tone: Tone
    let isDisabled: Bool
    let size: CGFloat
    let action: () -> Void

    init(
        symbolName: String,
        label: String,
        helpText: String,
        tone: Tone = .quiet,
        isDisabled: Bool,
        size: CGFloat = 28,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.label = label
        self.helpText = helpText
        self.tone = tone
        self.isDisabled = isDisabled
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: size <= 24 ? 10.5 : 11, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(CodexQuietButtonStyle(horizontalPadding: 0, verticalPadding: 0))
        .foregroundStyle(foregroundStyle)
        .accessibilityLabel(label)
        .accessibilityHint(helpText)
        .help(helpText)
        .disabled(isDisabled)
    }

    private var foregroundStyle: Color {
        if isDisabled, tone != .selected {
            return CodexTheme.disabledText
        }

        switch tone {
        case .quiet:
            return CodexTheme.utilityActionText
        case .accent:
            return CodexTheme.actionText
        case .selected:
            return CodexTheme.dataValueText
        }
    }

}

private struct ProfileSummaryPinnedAccessory: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(CodexTheme.quietText)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                    )
            )
            .accessibilityHidden(true)
    }
}

private struct ProfileSummaryExpiryLine: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let presentation: DisplayFormatter.LabeledValue
    let emphasisToken: CodexColorToken?
    let textScale: Double

    init(
        presentation: DisplayFormatter.LabeledValue,
        emphasisToken: CodexColorToken?,
        textScale: Double = 1
    ) {
        self.presentation = presentation
        self.emphasisToken = emphasisToken
        self.textScale = textScale
    }

    var body: some View {
        LabeledValueText(
            presentation: presentation,
            labelColor: CodexTheme.palette(for: themeContext.preset).dataLabelText.color,
            valueColor: emphasisToken?.color ?? CodexTheme.palette(for: themeContext.preset).dataValueText.color,
            font: ProfileManagerTypography.caption(scale: textScale)
        )
    }
}

struct ProfileUsageMetricBlock: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let summary: ProfileUsageMetricSummary
    let density: UsageMetricDensity
    let textScale: Double

    init(
        summary: ProfileUsageMetricSummary,
        density: UsageMetricDensity,
        textScale: Double = 1
    ) {
        self.summary = summary
        self.density = density
        self.textScale = textScale
    }

    private var accent: Color {
        if let remainingPercent = summary.remainingPercent {
            return CodexTheme.progressTextToken(forRemainingPercent: remainingPercent, preset: themeContext.preset).color
        }

        return CodexTheme.palette(for: themeContext.preset).mutedText.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * CGFloat(textScale)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summary.shortTitle)
                        .font(ProfileManagerTypography.caption(scale: textScale))
                        .foregroundStyle(CodexTheme.palette(for: themeContext.preset).dataLabelText.color)

                    if density == .expanded { Spacer(minLength: 0) }

                    Text(summary.valueText)
                        .font(density == .compact
                              ? ProfileManagerTypography.metricCompact(scale: textScale)
                              : ProfileManagerTypography.metricExpanded(scale: textScale))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                        .lineLimit(1)
                    if density == .compact { Spacer(minLength: 0) }
                }

                if density == .expanded, let percent = summary.remainingPercent {
                    CapacityRail(remainingPercent: percent)
                        .padding(.vertical, 4)
                }

                if summary.isAvailable {
                    let label = Text("Reset ")
                        .foregroundStyle(CodexTheme.palette(for: themeContext.preset).dataLabelText.color)
                    let value = Text(summary.resetText)
                        .foregroundStyle(CodexTheme.palette(for: themeContext.preset).supportText.color)
                    Text("\(label)\(value)")
                    .font(density.resetFont(scale: textScale))
                    .lineLimit(1)
                } else {
                    Text(summary.resetText)
                        .font(density.resetFont(scale: textScale))
                        .foregroundStyle(CodexTheme.palette(for: themeContext.preset).mutedText.color)
                        .lineLimit(1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.shortTitle)
        .accessibilityValue(summary.accessibilityValue)
    }
}

private struct CapacityRail: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let remainingPercent: Int

    var body: some View {
        // The bar is redundant with the numeric value and is intentionally quiet.
        Color.clear
            .frame(height: 4)
            .background(CodexTheme.surfaceToken(for: .nested, preset: themeContext.preset).color, in: Capsule())
            .overlay(alignment: .leading) {
                Color.clear
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(CodexTheme.progressTextToken(forRemainingPercent: remainingPercent, preset: themeContext.preset).color)
                            .scaleEffect(x: CGFloat(min(max(remainingPercent, 0), 100)) / 100, y: 1, anchor: .leading)
                    }
            }
            .accessibilityHidden(true)
    }
}

enum UsageMetricDensity {
    case compact
    case expanded

    func resetFont(scale: Double = 1) -> Font {
        switch self {
        case .compact:
            return ProfileManagerTypography.caption(scale: scale)
        case .expanded:
            return ProfileManagerTypography.small(scale: scale)
        }
    }
}

enum ProfileManagerTypography {
    static let micro = Font.codexUtility(size: 11, weight: .medium, relativeTo: .caption2)
    static let title = Font.codexUtility(size: 20, weight: .semibold, relativeTo: .title2)
    static let body = Font.codexUtility(size: 13, weight: .regular, relativeTo: .body)
    static let bodyStrong = Font.codexUtility(size: 13, weight: .semibold, relativeTo: .body)
    static let small = Font.codexUtility(size: 13, weight: .regular, relativeTo: .subheadline)
    static let smallStrong = Font.codexUtility(size: 13, weight: .semibold, relativeTo: .subheadline)
    static let caption = Font.codexUtility(size: 12, weight: .medium, relativeTo: .caption)

    static func micro(scale: Double) -> Font {
        Font.codexUtility(size: scaled(11, by: scale), weight: .medium, relativeTo: .caption2)
    }

    static func bodyStrong(scale: Double) -> Font {
        Font.codexUtility(size: scaled(13, by: scale), weight: .semibold, relativeTo: .body)
    }

    static func small(scale: Double) -> Font {
        Font.codexUtility(size: scaled(13, by: scale), weight: .regular, relativeTo: .subheadline)
    }

    static func smallStrong(scale: Double) -> Font {
        Font.codexUtility(size: scaled(13, by: scale), weight: .semibold, relativeTo: .subheadline)
    }

    static func caption(scale: Double) -> Font {
        Font.codexUtility(size: scaled(12, by: scale), weight: .medium, relativeTo: .caption)
    }

    static func metricCompact(scale: Double) -> Font {
        Font.codexUtility(size: scaled(16, by: scale), weight: .semibold, relativeTo: .headline)
    }

    static func metricExpanded(scale: Double) -> Font {
        Font.codexUtility(size: scaled(28, by: scale), weight: .semibold, relativeTo: .title2)
    }

    private static func scaled(_ size: CGFloat, by scale: Double) -> CGFloat {
        max(10, size * CGFloat(MenuBarPanelTextScalePreference.normalizedTextScale(scale)))
    }
}
