import SwiftUI

struct ProfileListPresentation: Equatable, Sendable {
    let displayedProfiles: [PlusProfileSnapshot]
    let filterBar: ProfileFilterBarPresentation

    init(
        profiles: [PlusProfileSnapshot],
        filter: ProfileFilter,
        query: String,
        displayOrder: ProfileDisplayOrder = ProfileDisplayOrder.defaultOrder
    ) {
        let filteredProfiles = filter.apply(to: profiles)
        let orderedProfiles = PlusProfileSnapshot.displayOrder(filteredProfiles, by: displayOrder)
        displayedProfiles = ProfileSearch.filter(orderedProfiles, query: query)
        filterBar = ProfileFilterBarPresentation(
            filter: filter,
            shownCount: displayedProfiles.count,
            totalCount: profiles.count,
            fullFiveHourLimitCount: profiles.count(where: \.hasFullFiveHourLimit),
            tagCounts: ProfileTagCounts(snapshots: profiles)
        )
    }
}

struct ProfileListControlsBar: View {
    let filterPresentation: ProfileFilterBarPresentation
    @Binding var displayOrder: ProfileDisplayOrder
    let textScale: Double
    let clearFilter: () -> Void
    let toggleFullLimit: () -> Void
    let toggleTag: (PlusProfileTag) -> Void

    init(
        filterPresentation: ProfileFilterBarPresentation,
        displayOrder: Binding<ProfileDisplayOrder>,
        textScale: Double = 1,
        clearFilter: @escaping () -> Void,
        toggleFullLimit: @escaping () -> Void,
        toggleTag: @escaping (PlusProfileTag) -> Void
    ) {
        self.filterPresentation = filterPresentation
        _displayOrder = displayOrder
        self.textScale = textScale
        self.clearFilter = clearFilter
        self.toggleFullLimit = toggleFullLimit
        self.toggleTag = toggleTag
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8 * CGFloat(textScale)) {
            ProfileFilterBar(
                presentation: filterPresentation,
                textScale: textScale,
                clearFilter: clearFilter,
                toggleFullLimit: toggleFullLimit,
                toggleTag: toggleTag
            )
            .layoutPriority(1)

            ProfileDisplayOrderMenu(
                displayOrder: $displayOrder,
                textScale: textScale
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile list controls")
    }
}

struct ProfileFilterBarPresentation: Equatable, Sendable {
    let filter: ProfileFilter
    let shownCount: Int
    let totalCount: Int
    let fullFiveHourLimitCount: Int
    let tagCounts: ProfileTagCounts

    init(
        filter: ProfileFilter,
        shownCount: Int,
        totalCount: Int,
        fullFiveHourLimitCount: Int = 0,
        tagCounts: ProfileTagCounts = ProfileTagCounts()
    ) {
        self.filter = filter
        self.shownCount = shownCount
        self.totalCount = totalCount
        self.fullFiveHourLimitCount = fullFiveHourLimitCount
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
        let fullLimitText = fullFiveHourLimitCount == 1
            ? "1 profile with full 5-hour limit"
            : "\(fullFiveHourLimitCount) profiles with full 5-hour limits"
        return "\(visibleSummaryText), \(fullLimitText), \(tagCounts.accessibilityText)"
    }

    var isAllSelected: Bool {
        filter.isEmpty
    }

    func isSelected(_ tag: PlusProfileTag) -> Bool {
        filter.isSelected(tag)
    }

    var isFullFiveHourLimitSelected: Bool {
        filter.showsOnlyFullFiveHourLimit
    }

    var statusCountText: String {
        tagCounts.statusText
    }

    var segments: [ProfileFilterSegment] {
        let allSegment = ProfileFilterSegment(
            kind: .all,
            title: "All",
            count: totalCount,
            isSelected: isAllSelected,
            isEnabled: totalCount > 0,
            accessibilityLabel: "All profiles"
        )

        let fullLimitSegment = ProfileFilterSegment(
            kind: .fullFiveHourLimit,
            title: "Full",
            count: fullFiveHourLimitCount,
            isSelected: isFullFiveHourLimitSelected,
            isEnabled: fullFiveHourLimitCount > 0 || isFullFiveHourLimitSelected,
            accessibilityLabel: "Full 5-hour limit, 100 percent remaining"
        )

        let tagSegments = PlusProfileTag.allCases.map { tag in
            let count = tagCounts.count(for: tag)
            return ProfileFilterSegment(
                kind: .tag(tag),
                title: tag.shortDisplayName,
                count: count,
                isSelected: isSelected(tag),
                isEnabled: count > 0 || isSelected(tag),
                accessibilityLabel: tag.displayName
            )
        }

        return [allSegment, fullLimitSegment] + tagSegments
    }
}

enum ProfileFilterSegmentKind: Hashable, Sendable {
    case all
    case fullFiveHourLimit
    case tag(PlusProfileTag)

    var id: String {
        switch self {
        case .all:
            return "all"
        case .fullFiveHourLimit:
            return "full-five-hour-limit"
        case let .tag(tag):
            return "tag-\(tag.id)"
        }
    }

    var tag: PlusProfileTag? {
        guard case let .tag(tag) = self else {
            return nil
        }

        return tag
    }

    var systemImage: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case .fullFiveHourLimit:
            return "gauge.high"
        case let .tag(tag):
            return tag.systemImage
        }
    }
}

struct ProfileFilterSegment: Identifiable, Equatable, Sendable {
    let kind: ProfileFilterSegmentKind
    let title: String
    let count: Int
    let isSelected: Bool
    let isEnabled: Bool
    let accessibilityLabel: String

    var id: String {
        kind.id
    }

    var tag: PlusProfileTag? {
        kind.tag
    }

    var displayText: String {
        "\(title) \(count)"
    }
}

struct ProfileFilterBar: View {
    let presentation: ProfileFilterBarPresentation
    let textScale: Double
    let clearFilter: () -> Void
    let toggleFullLimit: () -> Void
    let toggleTag: (PlusProfileTag) -> Void

    init(
        presentation: ProfileFilterBarPresentation,
        textScale: Double = 1,
        clearFilter: @escaping () -> Void,
        toggleFullLimit: @escaping () -> Void,
        toggleTag: @escaping (PlusProfileTag) -> Void
    ) {
        self.presentation = presentation
        self.textScale = textScale
        self.clearFilter = clearFilter
        self.toggleFullLimit = toggleFullLimit
        self.toggleTag = toggleTag
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4 * CGFloat(textScale)) {
                ForEach(presentation.segments) { segment in
                    ProfileFilterSegmentButton(
                        segment: segment,
                        textScale: textScale,
                        action: {
                            activate(segment)
                        }
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            ProfileFilterMenu(
                presentation: presentation,
                textScale: textScale,
                clearFilter: clearFilter,
                toggleFullLimit: toggleFullLimit,
                toggleTag: toggleTag
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile filters")
        .accessibilityValue(presentation.accessibilitySummaryText)
    }

    private func activate(_ segment: ProfileFilterSegment) {
        guard segment.isEnabled else {
            return
        }

        switch segment.kind {
        case .all:
            clearFilter()
        case .fullFiveHourLimit:
            toggleFullLimit()
        case let .tag(tag):
            toggleTag(tag)
        }
    }
}

private struct ProfileFilterSegmentButton: View {
    let segment: ProfileFilterSegment
    let textScale: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4 * CGFloat(textScale)) {
                if segment.isSelected, segment.kind != .all {
                    Image(systemName: segment.kind.systemImage)
                        .font(.system(size: 8 * CGFloat(textScale), weight: .semibold))
                        .frame(width: 9 * CGFloat(textScale), height: 9 * CGFloat(textScale))
                        .foregroundStyle(selectedIconColor)
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
                    .stroke(borderColor, lineWidth: CodexTheme.profileTagBorderLineWidth)
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

        if segment.kind == .fullFiveHourLimit {
            return CodexTheme.usagePercentageColor(forRemainingPercent: 100).opacity(0.28)
        }

        return CodexTheme.accentBlue.opacity(0.28)
    }

    private var selectedIconColor: Color {
        if let tag = segment.tag {
            return tag.profileTagTone.foregroundColor
        }

        if segment.kind == .fullFiveHourLimit {
            return CodexTheme.usagePercentageColor(forRemainingPercent: 100)
        }

        return CodexTheme.primaryText
    }

    private var helpText: String {
        if segment.isEnabled == false {
            if segment.kind == .fullFiveHourLimit {
                return "No profiles have a full 5H limit"
            }

            return "No \(segment.accessibilityLabel.lowercased()) profiles"
        }

        if segment.kind == .fullFiveHourLimit {
            return segment.isSelected
                ? "Stop showing only full 5H limits"
                : "Show only profiles with 5H at 100%"
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

private struct ProfileFilterMenu: View {
    let presentation: ProfileFilterBarPresentation
    let textScale: Double
    let clearFilter: () -> Void
    let toggleFullLimit: () -> Void
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

                Button("Clear filters", action: clearFilter)
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

    private func activate(_ segment: ProfileFilterSegment) {
        guard segment.isEnabled else {
            return
        }

        switch segment.kind {
        case .all:
            clearFilter()
        case .fullFiveHourLimit:
            toggleFullLimit()
        case let .tag(tag):
            toggleTag(tag)
        }
    }

    private func symbolName(for segment: ProfileFilterSegment) -> String {
        if segment.isSelected {
            return "checkmark"
        }

        return segment.kind.systemImage
    }
}

private struct ProfileDisplayOrderMenu: View {
    @Binding var displayOrder: ProfileDisplayOrder
    let textScale: Double

    var body: some View {
        Menu {
            Picker("Sort profiles", selection: $displayOrder) {
                ForEach(ProfileDisplayOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage)
                        .tag(order)
                }
            }
        } label: {
            HStack(spacing: 6 * CGFloat(textScale)) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11 * CGFloat(textScale), weight: .semibold))
                    .foregroundStyle(CodexTheme.utilityActionText)

                Text(displayOrder.compactTitle)
                    .lineLimit(1)
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
        .fixedSize(horizontal: true, vertical: false)
        .help(displayOrder.accessibilityValue)
        .accessibilityLabel("Sort profiles")
        .accessibilityValue(displayOrder.accessibilityValue)
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
                        .stroke(
                            tag.profileTagTone.borderColor(isSelected: true),
                            lineWidth: CodexTheme.profileTagBorderLineWidth
                        )
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
                        .stroke(borderColor, lineWidth: CodexTheme.profileTagBorderLineWidth)
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

struct ProfileFilterEmptyState: View {
    let clearFilter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No profiles match these filters.")
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
