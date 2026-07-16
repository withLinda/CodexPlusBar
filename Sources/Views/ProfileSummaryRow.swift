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
    let presentation: ProfileSummaryRowPresentation
    let mode: ProfileSummaryRowMode
    let textScale: Double
    let primaryAction: (() -> Void)?
    let copyAction: (() -> Void)?
    let emailAction: (() -> Void)?
    let pinAction: (() -> Void)?

    init(
        snapshot: PlusProfileSnapshot,
        referenceDate: Date = .now,
        mode: ProfileSummaryRowMode,
        textScale: Double = 1,
        searchPhoneNumber: String? = nil,
        primaryAction: (() -> Void)? = nil,
        copyAction: (() -> Void)? = nil,
        emailAction: (() -> Void)? = nil,
        pinAction: (() -> Void)? = nil
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
            pinAction: pinAction
        )
    }

    init(
        presentation: ProfileSummaryRowPresentation,
        mode: ProfileSummaryRowMode,
        textScale: Double = 1,
        primaryAction: (() -> Void)? = nil,
        copyAction: (() -> Void)? = nil,
        emailAction: (() -> Void)? = nil,
        pinAction: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.mode = mode
        self.textScale = textScale
        self.primaryAction = primaryAction
        self.copyAction = copyAction
        self.emailAction = emailAction
        self.pinAction = pinAction
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
        .padding(.horizontal, isMenuBarMode ? 10 : 12)
        .padding(.vertical, isMenuBarMode ? scaled(8) : 10)
        .background(backgroundShape)
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
        VStack(alignment: .leading, spacing: 9) {
            wrappedPrimaryAction {
                sidebarContentBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sidebarContentBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            titleRow

            if let searchPhoneNumber = presentation.searchPhoneNumber {
                phoneSearchContextLine(searchPhoneNumber)
            }

            if let usageSummary = presentation.usageSummary {
                usageSummaryView(usageSummary, spacing: 8)
            }

            supportLine
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

                if presentation.showsInlineSecondaryActions {
                    topActionRail
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            wrappedPrimaryAction {
                VStack(alignment: .leading, spacing: scaled(8)) {
                    if let searchPhoneNumber = presentation.searchPhoneNumber {
                        phoneSearchContextLine(searchPhoneNumber)
                    }

                    if presentation.showsTags {
                        ProfileTagSummaryStrip(
                            summary: presentation.compactTagSummary,
                            textScale: effectiveTextScale
                        )
                    }

                    if let usageSummary = presentation.usageSummary {
                        usageSummaryView(usageSummary, spacing: scaled(6))
                    }

                    supportLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(presentation.title)
                .font(ProfileManagerTypography.smallStrong)
                .foregroundStyle(CodexTheme.dataValueText)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.88)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if presentation.showsTags {
                ProfileTagSummaryStrip(
                    summary: presentation.compactTagSummary,
                    textScale: 0.92
                )
                .layoutPriority(2)
            }

            if presentation.accessory != .none {
                accessoryView
            }
        }
    }

    private var menuBarTitleLabel: some View {
        Text(presentation.title)
            .font(ProfileManagerTypography.smallStrong(scale: effectiveTextScale))
            .foregroundStyle(CodexTheme.dataValueText)
            .lineLimit(1)
            .truncationMode(.middle)
            .minimumScaleFactor(0.9)
            .frame(minWidth: 40, alignment: .leading)
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
        HStack(spacing: 5) {
            ProfileSummaryInlineIconButton(
                symbolName: "doc.on.doc",
                label: "Copy profile label",
                helpText: "Copy profile label",
                isDisabled: copyAction == nil,
                size: 24,
                action: copyAction ?? {}
            )

            ProfileSummaryInlineIconButton(
                symbolName: "arrow.up.forward.square",
                label: "Open email link",
                helpText: presentation.canOpenEmailLink
                    ? "Open email link"
                    : "Add an email link in the manager to open it here",
                isDisabled: presentation.canOpenEmailLink == false || emailAction == nil,
                size: 24,
                action: emailAction ?? {}
            )

            if presentation.showsPinAction {
                ProfileSummaryInlineIconButton(
                    symbolName: presentation.pinActionSymbolName,
                    label: presentation.pinActionAccessibilityLabel,
                    helpText: presentation.isPinned
                        ? "This profile already drives the top menu bar summary."
                        : "Show this profile in the top menu bar summary.",
                    tone: presentation.isPinned ? .selected : .accent,
                    isDisabled: presentation.isPinned || pinAction == nil,
                    size: 24,
                    action: pinAction ?? {}
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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
                .lineLimit(1)
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
            .fill(CodexTheme.cardFill(for: isSelected ? .strong : .nested))
            .overlay {
                RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                    .stroke(
                        isSelected
                            ? CodexTheme.accentOrange.opacity(0.35)
                            : CodexTheme.surfaceBorder(for: .nested),
                        lineWidth: 1
                    )
            }
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
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .background(
            RoundedRectangle(cornerRadius: size <= 24 ? 7 : 8, style: .continuous)
                .fill(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: size <= 24 ? 7 : 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        )
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

    private var backgroundFill: Color {
        switch tone {
        case .quiet:
            return CodexTheme.surfaceFill(for: .subtle)
        case .accent:
            return CodexTheme.accentOrange.opacity(0.10)
        case .selected:
            return CodexTheme.surfaceFill(for: .subtle)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .quiet:
            return CodexTheme.surfaceBorder(for: .subtle)
        case .accent:
            return CodexTheme.accentOrange.opacity(0.24)
        case .selected:
            return CodexTheme.surfaceBorder(for: .subtle)
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
        Group {
            if let label = presentation.label {
                (
                    Text(label + " ")
                        .foregroundStyle(CodexTheme.dataLabelText)
                    + Text(presentation.value)
                        .foregroundStyle(emphasisToken?.color ?? CodexTheme.dataValueText)
                        .monospacedDigit()
                )
                .font(ProfileManagerTypography.caption(scale: textScale))
            } else {
                Text(presentation.value)
                    .font(ProfileManagerTypography.caption(scale: textScale))
                    .foregroundStyle(emphasisToken?.color ?? CodexTheme.dataValueText)
            }
        }
        .lineLimit(1)
    }
}

struct ProfileUsageMetricBlock: View {
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
            return CodexTheme.usagePercentageColor(forRemainingPercent: remainingPercent)
        }

        return CodexTheme.mutedText
    }

    var body: some View {
        CodexCard(
            tier: density.cardTier,
            accent: density == .expanded ? accent : nil,
            padding: density.padding(scale: textScale),
            shadow: false
        ) {
            VStack(alignment: .leading, spacing: density.contentSpacing(scale: textScale)) {
                if density == .compact {
                    HStack(alignment: .firstTextBaseline, spacing: 6 * CGFloat(textScale)) {
                        Text(summary.shortTitle)
                            .font(ProfileManagerTypography.caption(scale: textScale))
                            .foregroundStyle(CodexTheme.dataLabelText)

                        Text(summary.valueText)
                            .font(ProfileManagerTypography.metricCompact(scale: textScale))
                            .foregroundStyle(accent)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                } else {
                    Text(summary.shortTitle)
                        .font(ProfileManagerTypography.caption(scale: textScale))
                        .foregroundStyle(CodexTheme.dataLabelText)

                    Text(summary.valueText)
                        .font(ProfileManagerTypography.metricExpanded(scale: textScale))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                }

                if summary.isAvailable {
                    (Text("Reset ")
                        .foregroundStyle(CodexTheme.dataLabelText)
                     + Text(summary.resetText)
                        .foregroundStyle(CodexTheme.resetCountdownEmphasisColor))
                    .font(density.resetFont(scale: textScale))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                } else {
                    Text(summary.resetText)
                        .font(density.resetFont(scale: textScale))
                        .foregroundStyle(CodexTheme.mutedText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.shortTitle)
        .accessibilityValue(summary.accessibilityValue)
    }
}

enum UsageMetricDensity {
    case compact
    case expanded

    var cardTier: CodexSurfaceTier {
        switch self {
        case .compact:
            return .subtle
        case .expanded:
            return .nested
        }
    }

    func padding(scale: Double = 1) -> CGFloat {
        switch self {
        case .compact:
            return 7 * CGFloat(scale)
        case .expanded:
            return 12 * CGFloat(scale)
        }
    }

    func contentSpacing(scale: Double = 1) -> CGFloat {
        switch self {
        case .compact:
            return 4 * CGFloat(scale)
        case .expanded:
            return 8 * CGFloat(scale)
        }
    }

    func resetFont(scale: Double = 1) -> Font {
        switch self {
        case .compact:
            return ProfileManagerTypography.micro(scale: scale)
        case .expanded:
            return ProfileManagerTypography.small(scale: scale)
        }
    }
}

enum ProfileManagerTypography {
    static let micro = Font.codexUtility(size: 11, weight: .medium, relativeTo: .caption2)
    static let title = Font.codexUtility(size: 34, weight: .semibold, relativeTo: .largeTitle)
    static let body = Font.codexUtility(size: 15, weight: .regular, relativeTo: .body)
    static let bodyStrong = Font.codexUtility(size: 15, weight: .semibold, relativeTo: .body)
    static let small = Font.codexUtility(size: 13, weight: .regular, relativeTo: .subheadline)
    static let smallStrong = Font.codexUtility(size: 13, weight: .semibold, relativeTo: .subheadline)
    static let caption = Font.codexUtility(size: 12, weight: .medium, relativeTo: .caption)
    static let metricCompact = Font.codexUtility(size: 16, weight: .semibold, relativeTo: .headline)
    static let metricExpanded = Font.codexUtility(size: 30, weight: .semibold, relativeTo: .title2)

    static func micro(scale: Double) -> Font {
        Font.codexUtility(size: scaled(11, by: scale), weight: .medium, relativeTo: .caption2)
    }

    static func body(scale: Double) -> Font {
        Font.codexUtility(size: scaled(15, by: scale), weight: .regular, relativeTo: .body)
    }

    static func bodyStrong(scale: Double) -> Font {
        Font.codexUtility(size: scaled(15, by: scale), weight: .semibold, relativeTo: .body)
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
        Font.codexUtility(size: scaled(30, by: scale), weight: .semibold, relativeTo: .title2)
    }

    private static func scaled(_ size: CGFloat, by scale: Double) -> CGFloat {
        size * CGFloat(MenuBarPanelTextScalePreference.normalizedTextScale(scale))
    }
}
