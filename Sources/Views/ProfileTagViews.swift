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

        return "\(shownCount) shown of \(totalCount)"
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
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(
                        minimum: 96 * CGFloat(textScale),
                        maximum: 140 * CGFloat(textScale)
                    ),
                    spacing: 6 * CGFloat(textScale),
                    alignment: .leading
                ),
            ],
            alignment: .leading,
            spacing: 6 * CGFloat(textScale)
        ) {
            ProfileTagToggleChip(
                title: "All",
                systemImage: "line.3.horizontal.decrease.circle",
                isSelected: presentation.isAllSelected,
                textScale: textScale,
                action: clearFilter
            )

            ForEach(PlusProfileTag.allCases) { tag in
                ProfileTagToggleChip(
                    title: tag.displayName,
                    systemImage: tag.systemImage,
                    isSelected: presentation.isSelected(tag),
                    tone: tag.statusTone,
                    textScale: textScale,
                    action: {
                        toggleTag(tag)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile tag filters")
        .accessibilityValue("\(presentation.countText), \(presentation.statusCountText)")
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

struct ProfileTagToggleChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let tone: CodexStatusTone?
    let textScale: Double
    let helpText: String?
    let action: () -> Void

    init(
        title: String,
        systemImage: String = "tag",
        isSelected: Bool,
        tone: CodexStatusTone? = nil,
        textScale: Double = 1,
        helpText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.tone = tone
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
        tone?.foregroundColor ?? CodexTheme.accentAqua
    }

    private var foregroundColor: Color {
        if isSelected {
            return accentColor
        }

        return tone == nil ? CodexTheme.supportText : CodexTheme.quietText
    }

    private var iconColor: Color {
        if isSelected || tone != nil {
            return accentColor
        }

        return CodexTheme.supportText
    }

    private var backgroundColor: Color {
        guard let tone else {
            return isSelected ? CodexTheme.surfaceFill(for: .strong) : CodexTheme.surfaceFill(for: .subtle)
        }

        return isSelected ? tone.backgroundColor : CodexTheme.surfaceFill(for: .subtle)
    }

    private var borderColor: Color {
        guard let tone else {
            return isSelected
                ? CodexTheme.accentAqua.opacity(0.38)
                : CodexTheme.surfaceBorder(for: .subtle)
        }

        return isSelected ? tone.borderColor : tone.borderColor.opacity(0.46)
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
        .foregroundStyle(tag.statusTone.foregroundColor)
        .padding(.horizontal, 7 * CGFloat(textScale))
        .padding(.vertical, 4 * CGFloat(textScale))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tag.statusTone.backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(tag.statusTone.borderColor, lineWidth: 1)
                )
        )
        .accessibilityLabel(tag.displayName)
    }
}
