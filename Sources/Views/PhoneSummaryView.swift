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
    let presentation: PhoneSummaryPresentation
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
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
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title)
                .font(ProfileManagerTypography.title)
                .foregroundStyle(CodexTheme.headingText)

            Text(presentation.summaryText)
                .font(ProfileManagerTypography.body)
                .foregroundStyle(CodexTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    .foregroundStyle(CodexTheme.headingText)

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
    let group: ProfilePhoneNumberGroup
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        CodexCard(tier: .regular, shadow: false) {
            VStack(alignment: .leading, spacing: 12) {
                groupHeader

                Divider()
                    .overlay(CodexTheme.surfaceLine)

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
            PhoneSummaryIcon(systemName: "phone.fill", isNavigation: true)

            Text(group.phoneNumber)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(CodexTheme.dataValueText)
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
    let groups: [ProfilePhoneNumberGroup]
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        CodexCard(tier: .regular, shadow: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups) { group in
                    if let snapshot = group.profiles.first {
                        Button {
                            openProfile(snapshot.id)
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                PhoneSummaryIcon(systemName: "phone", isNavigation: false)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.phoneNumber)
                                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CodexTheme.dataValueText)
                                        .lineLimit(1)

                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(DisplayFormatter.privateProfileLabel(snapshot.label))
                                            .font(ProfileManagerTypography.caption)
                                            .foregroundStyle(CodexTheme.mutedText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        PhoneSummaryExpiryText(
                                            expiresAt: snapshot.expiresAt,
                                            referenceDate: referenceDate
                                        )
                                    }
                                }

                                Spacer(minLength: 12)

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
    let profiles: [PlusProfileSnapshot]
    let referenceDate: Date
    let openProfile: (UUID) -> Void

    var body: some View {
        CodexCard(tier: .regular, shadow: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(profiles) { snapshot in
                    Button {
                        openProfile(snapshot.id)
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            PhoneSummaryIcon(systemName: "phone.down", isNavigation: false)

                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(DisplayFormatter.privateProfileLabel(snapshot.label))
                                    .font(ProfileManagerTypography.smallStrong)
                                    .foregroundStyle(CodexTheme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                PhoneSummaryExpiryText(
                                    expiresAt: snapshot.expiresAt,
                                    referenceDate: referenceDate
                                )
                            }

                            Spacer(minLength: 12)

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
    let snapshot: PlusProfileSnapshot
    let referenceDate: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PhoneSummaryIcon(systemName: "person.crop.circle", isNavigation: false)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DisplayFormatter.privateProfileLabel(snapshot.label))
                    .font(ProfileManagerTypography.smallStrong)
                    .foregroundStyle(CodexTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                PhoneSummaryExpiryText(
                    expiresAt: snapshot.expiresAt,
                    referenceDate: referenceDate
                )
            }

            Spacer(minLength: 12)

            PhoneSummaryOpenProfileAccessory()
        }
        .modifier(PhoneSummaryRowLayout())
    }
}

private struct PhoneSummaryExpiryText: View {
    let expiresAt: Date?
    let referenceDate: Date

    private var presentation: PhoneSummaryExpiryPresentation {
        PhoneSummaryExpiryPresentation(
            expiresAt: expiresAt,
            referenceDate: referenceDate
        )
    }

    var body: some View {
        LabeledValueText(
            presentation: presentation.value,
            prefix: "· ",
            labelColor: presentation.emphasisToken?.color ?? CodexTheme.mutedText,
            valueColor: presentation.emphasisToken?.color ?? CodexTheme.mutedText,
            font: ProfileManagerTypography.caption
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}

private struct PhoneSummaryIcon: View {
    let systemName: String
    let isNavigation: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isNavigation ? CodexTheme.utilityActionText : CodexTheme.mutedText)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.iconCornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .nested))
            )
            .accessibilityHidden(true)
    }
}

private struct PhoneSummaryOpenProfileAccessory: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CodexTheme.utilityActionText)
            .frame(width: 28, height: 28, alignment: .trailing)
            .help("Open profile")
            .accessibilityHidden(true)
    }
}

private struct PhoneSummaryRowLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct PhoneSummaryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? CodexTheme.surfaceFill(for: .nested)
                            : Color.clear
                    )
            )
    }
}
