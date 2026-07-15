import SwiftUI

struct ProfileEmailSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool
    let textScale: Double

    init(text: Binding<String>, textScale: Double = 1) {
        _text = text
        self.textScale = textScale
    }

    var body: some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: scaled(12), weight: .semibold))
                .foregroundStyle(CodexTheme.searchAction)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $text,
                prompt: Text("Email address")
                    .foregroundStyle(CodexTheme.searchPromptText)
            )
            .font(ProfileManagerTypography.small(scale: textScale))
            .textFieldStyle(.plain)
            .foregroundStyle(CodexTheme.searchInputText)
            .focused($isFocused)
            .accessibilityLabel("Search profiles by email")
            .accessibilityHint("Type a full email or any part of an email.")

            if text.isEmpty == false {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: scaled(12), weight: .semibold))
                        .frame(width: scaled(22), height: scaled(22))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CodexTheme.searchAction)
                .help("Clear email search")
                .accessibilityLabel("Clear email search")
            }
        }
        .padding(.leading, scaled(10))
        .padding(.trailing, scaled(6))
        .frame(minHeight: scaled(34))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBackground)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
            .fill(CodexTheme.searchFieldFill)
            .overlay {
                RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                    .stroke(
                        isFocused
                            ? CodexTheme.searchFocusBorder
                            : CodexTheme.surfaceBorder(for: .nested),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * CGFloat(textScale)
    }

    private func clearSearch() {
        text = ""
        isFocused = true
    }
}

struct ProfileSearchEmptyState: View {
    let query: String
    let clearsTagFilter: Bool
    let textScale: Double
    let clear: () -> Void

    init(
        query: String,
        clearsTagFilter: Bool,
        textScale: Double = 1,
        clear: @escaping () -> Void
    ) {
        self.query = query
        self.clearsTagFilter = clearsTagFilter
        self.textScale = textScale
        self.clear = clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * CGFloat(textScale)) {
            Label("No matching profile", systemImage: "magnifyingglass")
                .font(ProfileManagerTypography.smallStrong(scale: textScale))
                .foregroundStyle(CodexTheme.primaryText)

            Text("No saved email contains “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .font(ProfileManagerTypography.small(scale: textScale))
                .foregroundStyle(CodexTheme.supportText)
                .fixedSize(horizontal: false, vertical: true)

            Button(clearsTagFilter ? "Clear search and tags" : "Clear search", action: clear)
                .buttonStyle(CodexQuietButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
