import SwiftUI

struct PhoneSummaryPresentation: Equatable, Sendable {
    let numberGroups: [ProfilePhoneNumberGroup]
    let profilesWithoutNumber: [PlusProfileSnapshot]

    var title: String { "Phone summary" }

    var sharedGroups: [ProfilePhoneNumberGroup] {
        numberGroups.filter { $0.profiles.count > 1 }
    }

    var singleUseGroups: [ProfilePhoneNumberGroup] {
        numberGroups.filter { $0.profiles.count == 1 }
    }

    var totalProfileCount: Int {
        numberGroups.reduce(0) { $0 + $1.profiles.count } + profilesWithoutNumber.count
    }

    var sharedProfileCount: Int {
        sharedGroups.reduce(0) { $0 + $1.profiles.count }
    }

    var summaryText: String {
        guard totalProfileCount > 0 else {
            return "No saved profiles yet."
        }

        return [
            sharedSummaryText,
            singleUseSummaryText,
            missingSummaryText,
        ].joined(separator: " ")
    }

    var navigationCountText: String? {
        totalProfileCount == 0 ? nil : String(totalProfileCount)
    }

    var navigationAccessibilityLabel: String {
        switch totalProfileCount {
        case 0:
            return "Phone summary, no profiles"
        case 1:
            return "Phone summary, 1 profile"
        default:
            return "Phone summary, \(totalProfileCount) profiles"
        }
    }

    var sharedSectionMetaText: String {
        let numberText = sharedGroups.count == 1 ? "1 number" : "\(sharedGroups.count) numbers"
        let profileText = sharedProfileCount == 1
            ? "1 profile"
            : "\(sharedProfileCount) profiles"
        return "\(numberText) · \(profileText)"
    }

    var singleUseSectionMetaText: String {
        singleUseGroups.count == 1 ? "1 profile" : "\(singleUseGroups.count) profiles"
    }

    var missingSectionMetaText: String {
        profilesWithoutNumber.count == 1 ? "1 profile" : "\(profilesWithoutNumber.count) profiles"
    }

    private var sharedSummaryText: String {
        switch sharedProfileCount {
        case 0:
            return "No profiles share a number."
        case 1:
            return "1 profile shares a number."
        default:
            return "\(sharedProfileCount) profiles share a number."
        }
    }

    private var singleUseSummaryText: String {
        switch singleUseGroups.count {
        case 0:
            return "No number is used once."
        case 1:
            return "1 profile uses a number once."
        default:
            return "\(singleUseGroups.count) profiles use a number once."
        }
    }

    private var missingSummaryText: String {
        switch profilesWithoutNumber.count {
        case 0:
            return "Every profile has a number."
        case 1:
            return "1 profile has no number."
        default:
            return "\(profilesWithoutNumber.count) profiles have no number."
        }
    }
}

struct PhoneSummaryExpiryPresentation: Equatable, Sendable {
    let value: DisplayFormatter.LabeledValue
    let emphasisToken: CodexColorToken?

    init(expiresAt: Date?, referenceDate: Date) {
        value = DisplayFormatter.expiryValue(expiresAt, referenceDate: referenceDate)
        emphasisToken = CodexTheme.expiryEmphasisToken(
            for: expiresAt,
            referenceDate: referenceDate
        )
    }

    var accessibilityText: String {
        if let label = value.label {
            return "\(label) \(value.value)"
        }

        return value.value
    }
}

struct PhoneSummaryView: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let presentation: PhoneSummaryPresentation
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader

                if presentation.totalProfileCount == 0 {
                    emptyState
                } else {
                    summarySections
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.summaryText)
    }

    private var pageHeader: some View {
        Text(presentation.title)
            .font(ProfileManagerTypography.title)
            .foregroundStyle(CodexTheme.palette(for: themeContext.preset).strongText.color)
    }

    @ViewBuilder
    private var summarySections: some View {
        if presentation.sharedGroups.isEmpty == false {
            PhoneSummarySection(
                title: "Shared",
                metaText: presentation.sharedSectionMetaText
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(presentation.sharedGroups) { group in
                        SharedNumberGroupView(
                            group: group,
                            referenceDate: referenceDate,
                            openProfile: openProfile
                        )
                    }
                }
            }
        }

        if presentation.singleUseGroups.isEmpty == false {
            PhoneSummarySection(
                title: "Used once",
                metaText: presentation.singleUseSectionMetaText
            ) {
                SingleUsePhoneNumberList(
                    groups: presentation.singleUseGroups,
                    referenceDate: referenceDate,
                    openProfile: openProfile
                )
            }
        }

        if presentation.profilesWithoutNumber.isEmpty == false {
            PhoneSummarySection(
                title: "No number",
                metaText: presentation.missingSectionMetaText
            ) {
                MissingPhoneNumberList(
                    profiles: presentation.profilesWithoutNumber,
                    referenceDate: referenceDate,
                    openProfile: openProfile
                )
            }
        }
    }

    private var emptyState: some View {
        CodexCard(tier: .strong, shadow: false) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CodexTheme.utilityActionText)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("No profiles")
                        .font(ProfileManagerTypography.bodyStrong)
                        .foregroundStyle(CodexTheme.headingText)

                    Text("Add a profile to build the phone summary.")
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.mutedText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PhoneSummarySection<Content: View>: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let title: String
    let metaText: String
    let content: Content

    init(
        title: String,
        metaText: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.metaText = metaText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(ProfileManagerTypography.bodyStrong)
                    .foregroundStyle(CodexTheme.palette(for: themeContext.preset).strongText.color)

                Text(metaText)
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(CodexTheme.mutedText)

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SharedNumberGroupView: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let group: ProfilePhoneNumberGroup
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        CodexCard(tier: .regular, padding: 12, shadow: false) {
            VStack(alignment: .leading, spacing: 8) {
                groupHeader

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.profiles) { snapshot in
                        profileButton(snapshot)
                    }
                }
            }
        }
    }

    private var groupHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(group.phoneNumber)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).dataValueText.color)
                .textSelection(.enabled)

            Spacer(minLength: 12)

            Text("\(group.profiles.count) profiles")
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.mutedText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.phoneNumber), used by \(group.profiles.count) profiles")
    }

    private func profileButton(_ snapshot: PlusProfileSnapshot) -> some View {
        Button {
            openProfile(snapshot.id)
        } label: {
            PhoneSummaryAccountRow(
                snapshot: snapshot,
                referenceDate: referenceDate
            )
        }
        .buttonStyle(PhoneSummaryRowButtonStyle())
        .accessibilityLabel(
            "Open profile \(DisplayFormatter.privateProfileLabel(snapshot.label)), "
                + PhoneSummaryExpiryPresentation(
                    expiresAt: snapshot.expiresAt,
                    referenceDate: referenceDate
                ).accessibilityText
        )
    }
}

private struct SingleUsePhoneNumberList: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let groups: [ProfilePhoneNumberGroup]
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        CodexCard(tier: .regular, padding: 12, shadow: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups) { group in
                    if let snapshot = group.profiles.first {
                        Button {
                            openProfile(snapshot.id)
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.phoneNumber)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CodexTheme.palette(for: themeContext.preset).dataValueText.color)
                                        .lineLimit(1)

                                    Text(DisplayFormatter.privateProfileLabel(snapshot.label))
                                        .font(ProfileManagerTypography.caption)
                                        .foregroundStyle(CodexTheme.mutedText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer(minLength: 8)

                                PhoneSummaryExpiryText(expiresAt: snapshot.expiresAt, referenceDate: referenceDate)

                                PhoneSummaryOpenProfileAccessory()
                            }
                            .modifier(PhoneSummaryRowLayout())
                        }
                        .buttonStyle(PhoneSummaryRowButtonStyle())
                        .accessibilityLabel(
                            "Open profile \(DisplayFormatter.privateProfileLabel(snapshot.label)), "
                                + "phone number \(group.phoneNumber), "
                                + PhoneSummaryExpiryPresentation(
                                    expiresAt: snapshot.expiresAt,
                                    referenceDate: referenceDate
                                ).accessibilityText
                        )
                    }
                }
            }
        }
    }
}

private struct MissingPhoneNumberList: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let profiles: [PlusProfileSnapshot]
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        CodexCard(tier: .regular, padding: 12, shadow: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(profiles) { snapshot in
                    Button {
                        openProfile(snapshot.id)
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Text(DisplayFormatter.privateProfileLabel(snapshot.label))
                                .font(ProfileManagerTypography.smallStrong)
                                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).primaryText.color)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 8)

                            PhoneSummaryExpiryText(expiresAt: snapshot.expiresAt, referenceDate: referenceDate)

                            PhoneSummaryOpenProfileAccessory()
                        }
                        .modifier(PhoneSummaryRowLayout())
                    }
                    .buttonStyle(PhoneSummaryRowButtonStyle())
                    .accessibilityLabel(
                        "Open profile \(DisplayFormatter.privateProfileLabel(snapshot.label)), "
                            + "no phone number, "
                            + PhoneSummaryExpiryPresentation(
                                expiresAt: snapshot.expiresAt,
                                referenceDate: referenceDate
                            ).accessibilityText
                    )
                }
            }
        }
    }
}

private struct PhoneSummaryAccountRow: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let snapshot: PlusProfileSnapshot
    let referenceDate: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(DisplayFormatter.privateProfileLabel(snapshot.label))
                .font(ProfileManagerTypography.smallStrong)
                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).primaryText.color)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            PhoneSummaryExpiryText(expiresAt: snapshot.expiresAt, referenceDate: referenceDate)

            PhoneSummaryOpenProfileAccessory()
        }
        .modifier(PhoneSummaryRowLayout())
    }
}

private struct PhoneSummaryExpiryText: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let expiresAt: Date?
    let referenceDate: Date

    private var presentation: PhoneSummaryExpiryPresentation {
        PhoneSummaryExpiryPresentation(
            expiresAt: expiresAt,
            referenceDate: referenceDate
        )
    }

    var body: some View {
        let color = CodexTheme.expiryEmphasisToken(for: expiresAt, referenceDate: referenceDate, preset: themeContext.preset)?.color
            ?? CodexTheme.palette(for: themeContext.preset).mutedText.color
        LabeledValueText(
            presentation: presentation.value,
            labelColor: CodexTheme.palette(for: themeContext.preset).mutedText.color,
            valueColor: color,
            font: ProfileManagerTypography.caption
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}

private struct PhoneSummaryOpenProfileAccessory: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CodexTheme.utilityActionTextToken(preset: themeContext.preset).color)
            .frame(width: 16, height: 20, alignment: .trailing)
            .help("Open profile")
            .accessibilityHidden(true)
    }
}

private struct PhoneSummaryRowLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct PhoneSummaryRowButtonStyle: ButtonStyle {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    @Environment(\.isFocused) private var isFocused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? CodexTheme.surfaceToken(for: .regular, preset: themeContext.preset).color
                            : Color.clear
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? CodexTheme.searchFocusBorderToken(preset: themeContext.preset).color : .clear, lineWidth: 2)
            }
    }
}
