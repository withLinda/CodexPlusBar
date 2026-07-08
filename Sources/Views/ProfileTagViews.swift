import SwiftUI

struct ProfileTagFilterBarPresentation: Equatable, Sendable {
    let filter: ProfileTagFilter
    let shownCount: Int
    let totalCount: Int
    let tagCounts: ProfileTagCounts

    init(
        filter: ProfileTagFilter,
        shownCount: Int,
        totalCount: Int,
        tagCounts: ProfileTagCounts = ProfileTagCounts()
    ) {
        self.filter = filter
        self.shownCount = shownCount
        self.totalCount = totalCount
        self.tagCounts = tagCounts
    }

    var countText: String {
        if totalCount == 0 {
            return "No profiles"
        }

        if shownCount == totalCount {
            return totalCount == 1 ? "1 profile" : "\(totalCount) profiles"
        }

        return "\(shownCount) of \(totalCount) shown"
    }

    var visibleSummaryText: String {
        countText
    }

    var accessibilitySummaryText: String {
        "\(visibleSummaryText), \(tagCounts.accessibilityText)"
    }

    var isAllSelected: Bool {
        filter.isEmpty
    }

    func isSelected(_ tag: PlusProfileTag) -> Bool {
        filter.isSelected(tag)
    }

    var statusCountText: String {
        tagCounts.statusText
    }

    var segments: [ProfileTagFilterSegment] {
        let allSegment = ProfileTagFilterSegment(
            tag: nil,
            title: "All",
            count: totalCount,
            isSelected: isAllSelected,
            isEnabled: totalCount > 0,
            accessibilityLabel: "All profiles"
        )

        return [allSegment] + PlusProfileTag.allCases.map { tag in
            let count = tagCounts.count(for: tag)
            return ProfileTagFilterSegment(
                tag: tag,
                title: tag.shortDisplayName,
                count: count,
                isSelected: isSelected(tag),
                isEnabled: count > 0 || isSelected(tag),
                accessibilityLabel: tag.displayName
            )
        }
    }
}

struct ProfileTagFilterSegment: Identifiable, Equatable, Sendable {
    let tag: PlusProfileTag?
    let title: String
    let count: Int
    let isSelected: Bool
    let isEnabled: Bool
    let accessibilityLabel: String

    var id: String {
        tag?.id ?? "all"
    }

    var displayText: String {
        "\(title) \(count)"
    }
}

enum ProfileTagChipLabelStyle: Sendable, Equatable {
    case full
    case short

    func title(for tag: PlusProfileTag) -> String {
        switch self {
        case .full:
            return tag.displayName
        case .short:
            return tag.shortDisplayName
        }
    }
}

struct ProfileTagFilterBar: View {
    let presentation: ProfileTagFilterBarPresentation
    let textScale: Double
    let clearFilter: () -> Void
    let toggleTag: (PlusProfileTag) -> Void

    init(
        presentation: ProfileTagFilterBarPresentation,
        textScale: Double = 1,
        clearFilter: @escaping () -> Void,
        toggleTag: @escaping (PlusProfileTag) -> Void
    ) {
        self.presentation = presentation
        self.textScale = textScale
        self.clearFilter = clearFilter
        self.toggleTag = toggleTag
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4 * CGFloat(textScale)) {
                ForEach(presentation.segments) { segment in
                    ProfileTagSegmentButton(
                        segment: segment,
                        textScale: textScale,
                        action: {
                            activate(segment)
                        }
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            ProfileTagFilterMenu(
                presentation: presentation,
                textScale: textScale,
                clearFilter: clearFilter,
                toggleTag: toggleTag
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile filters")
        .accessibilityValue(presentation.accessibilitySummaryText)
    }

    private func activate(_ segment: ProfileTagFilterSegment) {
        guard segment.isEnabled else {
            return
        }

        if let tag = segment.tag {
            toggleTag(tag)
        } else {
            clearFilter()
        }
    }
}

private struct ProfileTagSegmentButton: View {
    let segment: ProfileTagFilterSegment
    let textScale: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4 * CGFloat(textScale)) {
                if segment.isSelected, let tag = segment.tag {
                    Image(systemName: tag.systemImage)
                        .font(.system(size: 8 * CGFloat(textScale), weight: .semibold))
                        .frame(width: 9 * CGFloat(textScale), height: 9 * CGFloat(textScale))
                        .foregroundStyle(tag.profileTagTone.foregroundColor)
                }

                Text(segment.title)
                    .lineLimit(1)

                Text("\(segment.count)")
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .font(ProfileManagerTypography.micro(scale: textScale))
        .padding(.horizontal, 6 * CGFloat(textScale))
        .padding(.vertical, 5 * CGFloat(textScale))
        .background(backgroundShape)
        .foregroundStyle(foregroundStyle)
        .buttonStyle(.plain)
        .disabled(segment.isEnabled == false)
        .help(helpText)
        .accessibilityLabel(segment.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                segment.isSelected
                    ? CodexTheme.surfaceFill(for: .strong)
                    : CodexTheme.surfaceFill(for: .subtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    private var foregroundStyle: Color {
        guard segment.isEnabled else {
            return CodexTheme.quietText
        }

        return segment.isSelected ? CodexTheme.primaryText : CodexTheme.supportText
    }

    private var borderColor: Color {
        guard segment.isSelected else {
            return CodexTheme.surfaceBorder(for: .subtle)
        }

        if let tag = segment.tag {
            return tag.profileTagTone.borderColor(isSelected: true)
        }

        return CodexTheme.accentBlue.opacity(0.28)
    }

    private var helpText: String {
        if segment.isEnabled == false {
            return "No \(segment.accessibilityLabel.lowercased()) profiles"
        }

        if segment.isSelected, segment.tag != nil {
            return "Remove \(segment.accessibilityLabel) filter"
        }

        return segment.tag == nil ? "Show all profiles" : "Filter by \(segment.accessibilityLabel)"
    }

    private var accessibilityValue: String {
        let profileText = segment.count == 1 ? "1 profile" : "\(segment.count) profiles"
        return segment.isSelected ? "\(profileText), selected" : profileText
    }
}

private struct ProfileTagFilterMenu: View {
    let presentation: ProfileTagFilterBarPresentation
    let textScale: Double
    let clearFilter: () -> Void
    let toggleTag: (PlusProfileTag) -> Void

    var body: some View {
        Menu {
            ForEach(presentation.segments) { segment in
                Button {
                    activate(segment)
                } label: {
                    Label(segment.displayText, systemImage: symbolName(for: segment))
                }
                .disabled(segment.isEnabled == false)
            }

            if presentation.isAllSelected == false {
                Divider()

                Button("Clear filter", action: clearFilter)
            }
        } label: {
            HStack(spacing: 6 * CGFloat(textScale)) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11 * CGFloat(textScale), weight: .semibold))

                Text("Filter")
                    .lineLimit(1)

                Text(presentation.visibleSummaryText)
                    .foregroundStyle(CodexTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(ProfileManagerTypography.caption(scale: textScale))
            .foregroundStyle(CodexTheme.primaryText)
            .padding(.horizontal, 9 * CGFloat(textScale))
            .padding(.vertical, 6 * CGFloat(textScale))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Filter profiles")
        .accessibilityLabel("Filter profiles")
        .accessibilityValue(presentation.accessibilitySummaryText)
    }

    private func activate(_ segment: ProfileTagFilterSegment) {
        guard segment.isEnabled else {
            return
        }

        if let tag = segment.tag {
            toggleTag(tag)
        } else {
            clearFilter()
        }
    }

    private func symbolName(for segment: ProfileTagFilterSegment) -> String {
        if segment.isSelected {
            return "checkmark"
        }

        return segment.tag?.systemImage ?? "line.3.horizontal.decrease.circle"
    }
}

struct ProfileTagStrip: View {
    let tags: [PlusProfileTag]
    let textScale: Double
    let labelStyle: ProfileTagChipLabelStyle

    init(
        tags: [PlusProfileTag],
        textScale: Double = 1,
        labelStyle: ProfileTagChipLabelStyle = .full
    ) {
        self.tags = PlusProfile.normalizedTags(tags)
        self.textScale = textScale
        self.labelStyle = labelStyle
    }

    var body: some View {
        if tags.isEmpty == false {
            HStack(spacing: 5 * CGFloat(textScale)) {
                ForEach(tags) { tag in
                    ProfileTagChip(tag: tag, textScale: textScale, labelStyle: labelStyle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Profile tags")
            .accessibilityValue(tags.map(\.displayName).joined(separator: ", "))
        }
    }
}

struct ProfileTagSummaryStrip: View {
    let summary: ProfileTagSummary
    let textScale: Double

    init(summary: ProfileTagSummary, textScale: Double = 1) {
        self.summary = summary
        self.textScale = textScale
    }

    var body: some View {
        if let primaryTag = summary.primaryTag {
            HStack(spacing: 4 * CGFloat(textScale)) {
                ProfileTagSummaryChip(tag: primaryTag, textScale: textScale)

                if summary.overflowCount > 0 {
                    Text("+\(summary.overflowCount)")
                        .font(ProfileManagerTypography.micro(scale: textScale))
                        .monospacedDigit()
                        .foregroundStyle(CodexTheme.mutedText)
                        .padding(.horizontal, 6 * CGFloat(textScale))
                        .padding(.vertical, 3 * CGFloat(textScale))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(CodexTheme.surfaceFill(for: .subtle))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                                )
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Profile tags")
            .accessibilityValue(summary.accessibilityValue)
        }
    }
}

private struct ProfileTagSummaryChip: View {
    let tag: PlusProfileTag
    let textScale: Double

    var body: some View {
        HStack(spacing: 4 * CGFloat(textScale)) {
            Image(systemName: tag.systemImage)
                .font(.system(size: 8.5 * CGFloat(textScale), weight: .semibold))
                .frame(width: 9 * CGFloat(textScale), height: 9 * CGFloat(textScale))

            Text(tag.shortDisplayName)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .font(ProfileManagerTypography.micro(scale: textScale))
        .foregroundStyle(tag.profileTagTone.foregroundColor)
        .padding(.horizontal, 6 * CGFloat(textScale))
        .padding(.vertical, 3 * CGFloat(textScale))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tag.profileTagTone.fillColor(isSelected: true))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(tag.profileTagTone.borderColor(isSelected: true), lineWidth: 1)
                )
        )
        .accessibilityLabel(tag.displayName)
    }
}

struct ProfileTagToggleChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let tagTone: CodexProfileTagTone?
    let textScale: Double
    let helpText: String?
    let action: () -> Void

    init(
        title: String,
        systemImage: String = "tag",
        isSelected: Bool,
        tagTone: CodexProfileTagTone? = nil,
        textScale: Double = 1,
        helpText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.tagTone = tagTone
        self.textScale = textScale
        self.helpText = helpText
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5 * CGFloat(textScale)) {
                Image(systemName: isSelected ? "checkmark" : systemImage)
                    .font(.system(size: 10 * CGFloat(textScale), weight: .semibold))
                    .frame(width: 11 * CGFloat(textScale), height: 11 * CGFloat(textScale))
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(ProfileManagerTypography.caption(scale: textScale))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .foregroundStyle(foregroundColor)
            }
            .padding(.horizontal, 9 * CGFloat(textScale))
            .padding(.vertical, 6 * CGFloat(textScale))
            .frame(minHeight: 28 * CGFloat(textScale))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        )
        .help(helpText ?? (isSelected ? "Remove \(title) filter" : "Filter by \(title)"))
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var accentColor: Color {
        tagTone?.foregroundColor ?? CodexTheme.accentBlue
    }

    private var foregroundColor: Color {
        if isSelected {
            return accentColor
        }

        return tagTone == nil ? CodexTheme.supportText : CodexTheme.quietText
    }

    private var iconColor: Color {
        if isSelected || tagTone != nil {
            return accentColor
        }

        return CodexTheme.supportText
    }

    private var backgroundColor: Color {
        guard let tagTone else {
            return isSelected ? CodexTheme.surfaceFill(for: .strong) : CodexTheme.surfaceFill(for: .subtle)
        }

        return tagTone.fillColor(isSelected: isSelected)
    }

    private var borderColor: Color {
        guard let tagTone else {
            return isSelected
                ? CodexTheme.accentBlue.opacity(0.38)
                : CodexTheme.surfaceBorder(for: .subtle)
        }

        return tagTone.borderColor(isSelected: isSelected)
    }
}

struct ProfileTagEmptyState: View {
    let clearFilter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No profiles match these tags.")
                .font(ProfileManagerTypography.small)
                .foregroundStyle(CodexTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Show all", action: clearFilter)
                .buttonStyle(CodexQuietButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct ProfileTagChip: View {
    let tag: PlusProfileTag
    let textScale: Double
    let labelStyle: ProfileTagChipLabelStyle

    var body: some View {
        HStack(spacing: 4 * CGFloat(textScale)) {
            Image(systemName: tag.systemImage)
                .font(.system(size: 8.5 * CGFloat(textScale), weight: .semibold))
                .frame(width: 9 * CGFloat(textScale), height: 9 * CGFloat(textScale))

            Text(labelStyle.title(for: tag))
                .font(ProfileManagerTypography.micro(scale: textScale))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(tag.profileTagTone.foregroundColor)
        .padding(.horizontal, 7 * CGFloat(textScale))
        .padding(.vertical, 4 * CGFloat(textScale))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tag.profileTagTone.fillColor(isSelected: true))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(tag.profileTagTone.borderColor(isSelected: true), lineWidth: 1)
                )
        )
        .accessibilityLabel(tag.displayName)
    }
}
