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
    let usageSummary: ProfileUsageSummary?
    let supportText: String
    let supportStyle: ProfileSummaryRowSupportStyle
    let accessory: ProfileSummaryRowAccessory
    let isPinned: Bool
    let showsStatusBadge: Bool
    let showsInlineSecondaryActions: Bool
    let canOpenEmailLink: Bool
    let showsPinnedCapsule: Bool
    let pinnedCapsuleTitle: String

    init(
        snapshot: PlusProfileSnapshot,
        referenceDate: Date = .now,
        mode: ProfileSummaryRowMode
    ) {
        title = snapshot.label
        let usageSummary = snapshot.usageSummary(referenceDate: referenceDate)
        self.usageSummary = usageSummary

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
            showsPinnedCapsule = false
            pinnedCapsuleTitle = ""
        case let .menuBar(isPinned):
            self.isPinned = isPinned
            switch (isPinned, snapshot.isRefreshing) {
            case (true, true):
                accessory = .pinnedAndRefreshing
            case (true, false):
                accessory = .pinned
            case (false, true):
                accessory = .refreshing
            case (false, false):
                accessory = .none
            }

            showsInlineSecondaryActions = true
            canOpenEmailLink = snapshot.profile.resolvedEmailLinkURL != nil
            showsPinnedCapsule = true
            pinnedCapsuleTitle = isPinned ? "On top" : "Show on top"
        }

        showsStatusBadge = false
    }
}

struct ProfileSummaryRow: View {
    let presentation: ProfileSummaryRowPresentation
    let mode: ProfileSummaryRowMode
    let primaryAction: (() -> Void)?
    let copyAction: (() -> Void)?
    let emailAction: (() -> Void)?
    let pinAction: (() -> Void)?

    init(
        snapshot: PlusProfileSnapshot,
        referenceDate: Date = .now,
        mode: ProfileSummaryRowMode,
        primaryAction: (() -> Void)? = nil,
        copyAction: (() -> Void)? = nil,
        emailAction: (() -> Void)? = nil,
        pinAction: (() -> Void)? = nil
    ) {
        self.init(
            presentation: ProfileSummaryRowPresentation(
                snapshot: snapshot,
                referenceDate: referenceDate,
                mode: mode
            ),
            mode: mode,
            primaryAction: primaryAction,
            copyAction: copyAction,
            emailAction: emailAction,
            pinAction: pinAction
        )
    }

    init(
        presentation: ProfileSummaryRowPresentation,
        mode: ProfileSummaryRowMode,
        primaryAction: (() -> Void)? = nil,
        copyAction: (() -> Void)? = nil,
        emailAction: (() -> Void)? = nil,
        pinAction: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.mode = mode
        self.primaryAction = primaryAction
        self.copyAction = copyAction
        self.emailAction = emailAction
        self.pinAction = pinAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let primaryAction {
                Button(action: primaryAction) {
                    contentBody
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                contentBody
            }

            if presentation.showsInlineSecondaryActions {
                actionRail
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(backgroundShape)
    }

    private var contentBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Text(presentation.title)
                    .font(ProfileManagerTypography.smallStrong)
                    .foregroundStyle(CodexTheme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if presentation.accessory != .none {
                    accessoryView
                }
            }

            if let usageSummary = presentation.usageSummary {
                HStack(alignment: .top, spacing: 8) {
                    ProfileUsageMetricBlock(
                        summary: usageSummary.primary,
                        density: .compact
                    )

                    ProfileUsageMetricBlock(
                        summary: usageSummary.secondary,
                        density: .compact
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Usage summary")
                .accessibilityValue(usageSummary.accessibilityValue)
            }

            Text(presentation.supportText)
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(presentation.supportStyle.foregroundStyle)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRail: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ProfileSummaryInlineIconButton(
                    symbolName: "doc.on.doc",
                    label: "Copy profile label",
                    helpText: "Copy profile label",
                    isDisabled: copyAction == nil,
                    action: copyAction ?? {}
                )

                ProfileSummaryInlineIconButton(
                    symbolName: "arrow.up.forward.square",
                    label: "Open email link",
                    helpText: presentation.canOpenEmailLink
                        ? "Open email link"
                        : "Add an email link in the manager to open it here",
                    isDisabled: presentation.canOpenEmailLink == false || emailAction == nil,
                    action: emailAction ?? {}
                )
            }

            Spacer(minLength: 0)

            if presentation.showsPinnedCapsule {
                ProfileSummaryPinnedCapsuleButton(
                    title: presentation.pinnedCapsuleTitle,
                    isPinned: presentation.isPinned,
                    isDisabled: presentation.isPinned || pinAction == nil,
                    action: pinAction ?? {}
                )
            }
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        HStack(spacing: 6) {
            if presentation.showsPinnedCapsule == false,
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
            .fill(isSelected ? CodexTheme.surfaceFill(for: .strong) : CodexTheme.surfaceFill(for: .nested))
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
    let symbolName: String
    let label: String
    let helpText: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? CodexTheme.quietText : CodexTheme.primaryText)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                )
        )
        .opacity(isDisabled ? 0.48 : 1)
        .accessibilityLabel(label)
        .accessibilityHint(helpText)
        .help(helpText)
        .disabled(isDisabled)
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

private struct ProfileSummaryPinnedCapsuleButton: View {
    let title: String
    let isPinned: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.codexMicro)
            .foregroundStyle(isPinned ? CodexTheme.primaryText : CodexTheme.accentOrange)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isPinned ? CodexTheme.surfaceFill(for: .subtle) : CodexTheme.accentOrange.opacity(0.10))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                isPinned
                                    ? CodexTheme.surfaceBorder(for: .subtle)
                                    : CodexTheme.accentOrange.opacity(0.24),
                                lineWidth: 1
                            )
                    )
            )
            .help(
                isPinned
                    ? "This profile already drives the top menu bar summary."
                    : "Show this profile in the top menu bar summary."
            )
            .accessibilityHint(
                isPinned
                    ? "Already pinned to the menu bar summary."
                    : "Pin this profile to the menu bar summary."
            )
            .disabled(isDisabled)
    }
}

struct ProfileUsageMetricBlock: View {
    let summary: ProfileUsageMetricSummary
    let density: UsageMetricDensity

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
            padding: density.padding,
            shadow: false
        ) {
            VStack(alignment: .leading, spacing: density.contentSpacing) {
                if density == .compact {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.shortTitle)
                            .font(ProfileManagerTypography.caption)
                            .foregroundStyle(CodexTheme.supportText)

                        Text(summary.valueText)
                            .font(ProfileManagerTypography.metricCompact)
                            .foregroundStyle(accent)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                } else {
                    Text(summary.shortTitle)
                        .font(ProfileManagerTypography.caption)
                        .foregroundStyle(CodexTheme.supportText)

                    Text(summary.valueText)
                        .font(ProfileManagerTypography.metricExpanded)
                        .foregroundStyle(accent)
                        .monospacedDigit()
                }

                if summary.isAvailable {
                    (Text("Reset ")
                        .foregroundStyle(CodexTheme.mutedText)
                     + Text(summary.resetText)
                        .foregroundStyle(CodexTheme.resetCountdownEmphasisColor))
                    .font(density.resetFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                } else {
                    Text(summary.resetText)
                        .font(density.resetFont)
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

    var padding: CGFloat {
        switch self {
        case .compact:
            return 8
        case .expanded:
            return 12
        }
    }

    var contentSpacing: CGFloat {
        switch self {
        case .compact:
            return 5
        case .expanded:
            return 8
        }
    }

    var resetFont: Font {
        switch self {
        case .compact:
            return ProfileManagerTypography.micro
        case .expanded:
            return ProfileManagerTypography.small
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
    static let metricCompact = Font.codexUtility(size: 17, weight: .semibold, relativeTo: .headline)
    static let metricExpanded = Font.codexUtility(size: 30, weight: .semibold, relativeTo: .title2)
}
