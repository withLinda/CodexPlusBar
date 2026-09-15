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
            limitCounts: ProfileLimitCounts(snapshots: profiles),
            tagCounts: ProfileTagCounts(snapshots: profiles),
            providerCounts: ProfileProviderCounts(snapshots: profiles)
        )
    }
}

struct ProfileListControlsBar: View {
    let filterPresentation: ProfileFilterBarPresentation
    @Binding var displayOrder: ProfileDisplayOrder
    let textScale: Double
    let clearFilter: () -> Void
    let toggleLimit: (ProfileLimitFilter) -> Void
    let toggleTag: (PlusProfileTag) -> Void
    let toggleProvider: (ProfileProvider) -> Void

    init(
        filterPresentation: ProfileFilterBarPresentation,
        displayOrder: Binding<ProfileDisplayOrder>,
        textScale: Double = 1,
        clearFilter: @escaping () -> Void,
        toggleLimit: @escaping (ProfileLimitFilter) -> Void,
        toggleTag: @escaping (PlusProfileTag) -> Void,
        toggleProvider: @escaping (ProfileProvider) -> Void
    ) {
        self.filterPresentation = filterPresentation
        _displayOrder = displayOrder
        self.textScale = textScale
        self.clearFilter = clearFilter
        self.toggleLimit = toggleLimit
        self.toggleTag = toggleTag
        self.toggleProvider = toggleProvider
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8 * CGFloat(textScale)) {
            ProfileFilterBar(
                presentation: filterPresentation,
                textScale: textScale,
                clearFilter: clearFilter,
                toggleLimit: toggleLimit,
                toggleTag: toggleTag,
                toggleProvider: toggleProvider
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
    let limitCounts: ProfileLimitCounts
    let tagCounts: ProfileTagCounts
    let providerCounts: ProfileProviderCounts

    init(
        filter: ProfileFilter,
        shownCount: Int,
        totalCount: Int,
        limitCounts: ProfileLimitCounts = ProfileLimitCounts(),
        tagCounts: ProfileTagCounts = ProfileTagCounts(),
        providerCounts: ProfileProviderCounts = ProfileProviderCounts()
    ) {
        self.filter = filter
        self.shownCount = shownCount
        self.totalCount = totalCount
        self.limitCounts = limitCounts
        self.tagCounts = tagCounts
        self.providerCounts = providerCounts
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

    var controlSummaryText: String {
        let activeLabels = activeFilterLabels
        switch activeLabels.count {
        case 0:
            return visibleSummaryText
        case 1:
            return "\(activeLabels[0]) · \(visibleSummaryText)"
        default:
            return "\(activeLabels.count) filters · \(visibleSummaryText)"
        }
    }

    var accessibilitySummaryText: String {
        var parts = [visibleSummaryText]
        let descriptions = activeFilterDescriptions
        if descriptions.isEmpty {
            parts.append("no filters")
        } else {
            parts.append(contentsOf: descriptions)
        }
        return parts.joined(separator: ", ")
    }

    var isAllSelected: Bool {
        filter.isEmpty
    }

    func isSelected(_ tag: PlusProfileTag) -> Bool {
        filter.isSelected(tag)
    }

    func isSelected(_ provider: ProfileProvider) -> Bool {
        filter.isSelected(provider)
    }

    func isSelected(_ limit: ProfileLimitFilter) -> Bool {
        filter.isSelected(limit)
    }

    var statusCountText: String {
        tagCounts.statusText
    }

    var allSegment: ProfileFilterSegment {
        ProfileFilterSegment(
            kind: .all,
            title: "All",
            count: totalCount,
            isSelected: isAllSelected,
            isEnabled: totalCount > 0,
            accessibilityLabel: "All profiles"
        )
    }

    var providerSegments: [ProfileFilterSegment] {
        if providerCounts.total > 0
            || filter.selectedProvider != nil {
            return ProfileProvider.allCases.map { provider in
                let count = providerCounts.count(for: provider)
                return ProfileFilterSegment(
                    kind: .provider(provider),
                    title: provider.displayName,
                    count: count,
                    isSelected: isSelected(provider),
                    isEnabled: count > 0 || isSelected(provider),
                    accessibilityLabel: "\(provider.displayName) profiles"
                )
            }
        }

        return []
    }

    var limitSegments: [ProfileFilterSegment] {
        ProfileLimitFilter.selectableCases.map { limit in
            let count = limitCounts.count(for: limit)
            return ProfileFilterSegment(
                kind: .limit(limit),
                title: limit.shortTitle,
                count: count,
                isSelected: isSelected(limit),
                isEnabled: count > 0 || isSelected(limit),
                accessibilityLabel: limit.accessibilityLabel
            )
        }
    }

    var tagSegments: [ProfileFilterSegment] {
        PlusProfileTag.allCases.map { tag in
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
    }

    var segments: [ProfileFilterSegment] {
        [allSegment] + providerSegments + limitSegments + tagSegments
    }

    private var activeFilterLabels: [String] {
        var labels: [String] = []
        if let selectedProvider = filter.selectedProvider {
            labels.append(selectedProvider.displayName)
        }
        if filter.selectedLimit != .any {
            labels.append(filter.selectedLimit.shortTitle)
        }
        labels.append(contentsOf: filter.selectedTags.map(\.shortDisplayName))
        return labels
    }

    private var activeFilterDescriptions: [String] {
        var descriptions: [String] = []
        if let selectedProvider = filter.selectedProvider {
            descriptions.append("\(selectedProvider.displayName) only")
        }
        if filter.selectedLimit != .any {
            descriptions.append(filter.selectedLimit.accessibilityLabel)
        }
        descriptions.append(contentsOf: filter.selectedTags.map { "\($0.displayName) status" })
        return descriptions
    }
}

enum ProfileFilterSegmentKind: Hashable, Sendable {
    case all
    case provider(ProfileProvider)
    case limit(ProfileLimitFilter)
    case tag(PlusProfileTag)

    var id: String {
        switch self {
        case .all:
            return "all"
        case let .provider(provider):
            return "provider-\(provider.id)"
        case let .limit(limit):
            return "limit-\(limit.id)"
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

    var provider: ProfileProvider? {
        guard case let .provider(provider) = self else {
            return nil
        }

        return provider
    }

    var limit: ProfileLimitFilter? {
        guard case let .limit(limit) = self else {
            return nil
        }

        return limit
    }

    var systemImage: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case let .provider(provider):
            return provider.systemImage
        case let .limit(limit):
            return limit.systemImage
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

    var provider: ProfileProvider? {
        kind.provider
    }

    var limit: ProfileLimitFilter? {
        kind.limit
    }

    var displayText: String {
        "\(title) \(count)"
    }
}

struct ProfileFilterBar: View {
    let presentation: ProfileFilterBarPresentation
    let textScale: Double
    let clearFilter: () -> Void
    let toggleLimit: (ProfileLimitFilter) -> Void
    let toggleTag: (PlusProfileTag) -> Void
    let toggleProvider: (ProfileProvider) -> Void

    init(
        presentation: ProfileFilterBarPresentation,
        textScale: Double = 1,
        clearFilter: @escaping () -> Void,
        toggleLimit: @escaping (ProfileLimitFilter) -> Void,
        toggleTag: @escaping (PlusProfileTag) -> Void,
        toggleProvider: @escaping (ProfileProvider) -> Void
    ) {
        self.presentation = presentation
        self.textScale = textScale
        self.clearFilter = clearFilter
        self.toggleLimit = toggleLimit
        self.toggleTag = toggleTag
        self.toggleProvider = toggleProvider
    }

    var body: some View {
        ProfileFilterMenu(
                presentation: presentation,
                textScale: textScale,
                clearFilter: clearFilter,
                toggleLimit: toggleLimit,
                toggleTag: toggleTag,
                toggleProvider: toggleProvider
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile filters")
        .accessibilityValue(presentation.accessibilitySummaryText)
    }

}

private struct ProfileFilterMenu: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let presentation: ProfileFilterBarPresentation
    let textScale: Double
    let clearFilter: () -> Void
    let toggleLimit: (ProfileLimitFilter) -> Void
    let toggleTag: (PlusProfileTag) -> Void
    let toggleProvider: (ProfileProvider) -> Void

    var body: some View {
        Menu {
            segmentButton(presentation.allSegment)

            if presentation.providerSegments.isEmpty == false {
                Menu {
                    segmentButtons(presentation.providerSegments)
                } label: {
                    Label("Provider", systemImage: "person.2")
                }
            }

            Menu {
                segmentButtons(presentation.limitSegments)
            } label: {
                Label("Limits", systemImage: "gauge")
            }

            Menu {
                segmentButtons(presentation.tagSegments)
            } label: {
                Label("Status", systemImage: "tag")
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

                if !presentation.isAllSelected {
                    Text(presentation.controlSummaryText)
                        .foregroundStyle(CodexTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(ProfileManagerTypography.caption(scale: textScale))
            .foregroundStyle(CodexTheme.palette(for: themeContext.preset).primaryText.color)
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

    @ViewBuilder
    private func segmentButtons(_ segments: [ProfileFilterSegment]) -> some View {
        ForEach(segments) { segment in
            segmentButton(segment)
        }
    }

    private func segmentButton(_ segment: ProfileFilterSegment) -> some View {
        Button {
            activate(segment)
        } label: {
            Label(segment.displayText, systemImage: symbolName(for: segment))
        }
        .disabled(segment.isEnabled == false)
    }

    private func activate(_ segment: ProfileFilterSegment) {
        guard segment.isEnabled else {
            return
        }

        switch segment.kind {
        case .all:
            clearFilter()
        case let .limit(limit):
            toggleLimit(limit)
        case let .tag(tag):
            toggleTag(tag)
        case let .provider(provider):
            toggleProvider(provider)
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
    @Environment(\.codexThemeRefreshContext) private var themeContext
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
            .foregroundStyle(CodexTheme.palette(for: themeContext.preset).primaryText.color)
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
    @Environment(\.codexThemeRefreshContext) private var themeContext
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
                        .foregroundStyle(CodexTheme.palette(for: themeContext.preset).mutedText.color)
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
    @Environment(\.codexThemeRefreshContext) private var themeContext
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
        .foregroundStyle(CodexTheme.profileTagTextToken(for: tag.profileTagTone, preset: themeContext.preset).color)
        .padding(.horizontal, 6 * CGFloat(textScale))
        .padding(.vertical, 3 * CGFloat(textScale))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(CodexTheme.profileTagFillToken(for: tag.profileTagTone, isSelected: true, preset: themeContext.preset).color)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                             CodexTheme.profileTagBorderToken(for: tag.profileTagTone, isSelected: true, preset: themeContext.preset).color,
                            lineWidth: CodexTheme.profileTagBorderLineWidth
                        )
                )
        )
        .accessibilityLabel(tag.displayName)
    }
}

struct ProfileTagToggleChip: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
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
        tagTone.map { CodexTheme.profileTagTextToken(for: $0, preset: themeContext.preset).color }
            ?? CodexTheme.searchActionToken(preset: themeContext.preset).color
    }

    private var foregroundColor: Color {
        if isSelected {
            return accentColor
        }

        let palette = CodexTheme.palette(for: themeContext.preset)
        return tagTone == nil ? palette.supportText.color : palette.quietText.color
    }

    private var iconColor: Color {
        if isSelected || tagTone != nil {
            return accentColor
        }

        return CodexTheme.palette(for: themeContext.preset).supportText.color
    }

    private var backgroundColor: Color {
        guard let tagTone else {
            return CodexTheme.surfaceToken(for: isSelected ? .strong : .subtle, preset: themeContext.preset).color
        }

        return CodexTheme.profileTagFillToken(for: tagTone, isSelected: isSelected, preset: themeContext.preset).color
    }

    private var borderColor: Color {
        guard let tagTone else {
            return isSelected
                ? CodexTheme.accentBlue.opacity(0.38)
                : CodexTheme.surfaceBorder(for: .subtle)
        }

        return CodexTheme.profileTagBorderToken(for: tagTone, isSelected: isSelected, preset: themeContext.preset).color
    }
}

struct ProfileFilterEmptyState: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let clearFilter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No profiles match these filters.")
                .font(ProfileManagerTypography.small)
                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).mutedText.color)
                .fixedSize(horizontal: false, vertical: true)

            Button("Show all", action: clearFilter)
                .buttonStyle(CodexQuietButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
