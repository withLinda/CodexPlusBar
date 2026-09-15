import SwiftUI

enum EmailToolsLayout {
    static let defaultSize = CGSize(width: 900, height: 620)
    static let minimumSize = CGSize(width: 760, height: 520)
    static let emptySize = CGSize(width: 640, height: 240)
    static let emptyMinimumSize = CGSize(width: 600, height: 240)
    static let sidebarWidth: CGFloat = 224
}

struct EmailToolsWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CodexThemeSettings.Keys.appearanceMode) private var appearance = CodexThemeSettings.defaultAppearanceMode
    @AppStorage(CodexThemeSettings.Keys.contrast) private var contrast = CodexThemeSettings.defaultContrast
    @Bindable var controller: DotTrickController
    @State private var inputDraft = ""
    @State private var searchQuery = ""
    @State private var copyFeedback = TransientValue<String>()
    @State private var confirmingDeleteID: UUID?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case input, filter }

    private var themeContext: CodexThemeRefreshContext {
        CodexThemeRefreshContext(appearanceMode: appearance, contrast: contrast, systemVariant: colorScheme == .dark ? .dark : .light)
    }

    var body: some View {
        CodexWindowChromeContainer(minimumSize: controller.sessions.isEmpty ? EmailToolsLayout.emptyMinimumSize : EmailToolsLayout.minimumSize) {
            VStack(alignment: .leading, spacing: 16) {
                header
                inputBar
                bodyContent
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(CodexTheme.utilityActionTextToken(preset: themeContext.preset).color)
        .alert(sessionRemovalTitle, isPresented: Binding(
            get: { confirmingDeleteID != nil },
            set: { if !$0 { confirmingDeleteID = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let id = confirmingDeleteID { controller.removeSession(id: id) }
                confirmingDeleteID = nil
            }
        } message: {
            Text("Its saved used-address marks will be removed.")
        }
        .onChange(of: controller.selectedSessionID) { _, _ in searchQuery = "" }
        .onDisappear { copyFeedback.clear() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Email tools")
                .font(ProfileManagerTypography.title)
                .foregroundStyle(CodexTheme.headingText)
            Spacer(minLength: 0)
            Text("Gmail address variants")
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.supportText)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $inputDraft, prompt: Text("Gmail username or address")
                .foregroundStyle(CodexTheme.searchPromptTextToken(preset: themeContext.preset).color))
                .font(ProfileManagerTypography.body)
                .textFieldStyle(.plain)
                .foregroundStyle(CodexTheme.dataValueText)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(fieldBackground(isFocused: focusedField == .input))
                .focused($focusedField, equals: .input)
                .accessibilityLabel("Gmail username or address")
                .accessibilityIdentifier("email-tools.input")
                .onSubmit(generateFromDraft)

            Button("Generate", action: generateFromDraft)
                .buttonStyle(CodexPrimaryButtonStyle())
                .disabled(!isInputValid)
                .accessibilityIdentifier("email-tools.generate")
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if controller.sessions.isEmpty {
            Text("Dots in a Gmail address all reach the same inbox.")
                .font(ProfileManagerTypography.small)
                .foregroundStyle(CodexTheme.supportText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HStack(alignment: .top, spacing: 16) {
                sidebar.frame(width: EmailToolsLayout.sidebarWidth)
                if let session = controller.selectedSession {
                    variationList(for: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved addresses")
                .font(ProfileManagerTypography.smallStrong)
                .foregroundStyle(CodexTheme.headingText)
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(controller.sessions) { session in
                        EmailToolsSidebarRow(
                            session: session,
                            isSelected: session.id == controller.selectedSessionID,
                            select: { controller.selectSession(id: session.id) },
                            remove: { confirmingDeleteID = session.id }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func variationList(for session: DotTrickSession) -> some View {
        let filtered = filteredVariations(for: session)
        let unusedCount = session.variationCount - session.usedCount
        let copiedAll = copyFeedback.current == "__all_\(session.id.uuidString)"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.canonicalEmail)
                        .font(ProfileManagerTypography.smallStrong)
                        .foregroundStyle(CodexTheme.headingText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.canonicalEmail)
                    Text("\(unusedCount) unused · \(session.usedCount) used")
                        .font(ProfileManagerTypography.caption)
                        .foregroundStyle(CodexTheme.supportText)
                }
                Spacer(minLength: 8)
                Button {
                    copyAllVariations(for: session)
                } label: {
                    Label(copiedAll ? "Copied" : session.usedCount > 0 ? "Copy unused" : "Copy all", systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.caption, foregroundColor: CodexTheme.utilityActionText, horizontalPadding: 10))
                .disabled(unusedCount == 0)
                .help("Copy addresses not marked as used")
                .accessibilityIdentifier("email-tools.copy-unused")
            }

            if session.variationCount > 6 {
                TextField("", text: $searchQuery, prompt: Text("Filter addresses")
                    .foregroundStyle(CodexTheme.searchPromptTextToken(preset: themeContext.preset).color))
                    .font(ProfileManagerTypography.small)
                    .textFieldStyle(.plain)
                    .foregroundStyle(CodexTheme.dataValueText)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .background(fieldBackground(isFocused: focusedField == .filter))
                    .focused($focusedField, equals: .filter)
                    .accessibilityLabel("Filter address variants")
                    .accessibilityIdentifier("email-tools.filter")
                    .onExitCommand { searchQuery = "" }
            }

            if !searchQuery.isEmpty {
                Text("\(filtered.count) of \(session.variationCount) addresses")
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(CodexTheme.supportText)
            }

            if filtered.isEmpty {
                Button("Clear filter") { searchQuery = "" }
                    .buttonStyle(CodexQuietButtonStyle())
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(filtered, id: \.self) { variation in
                        EmailToolsVariationRow(
                            variation: variation,
                            isUsed: session.isUsed(variation),
                            isCopied: copyFeedback.current == variation,
                            toggleUsed: { controller.toggleUsed(variation: variation, inSession: session.id) },
                            copy: { copyToPasteboard(variation, feedback: variation) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fieldBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
            .fill(CodexTheme.surfaceFill(for: .nested))
            .overlay {
                RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? CodexTheme.searchFocusBorder : CodexTheme.controlBoundary, lineWidth: isFocused ? 2 : 1)
            }
    }

    private var isInputValid: Bool { DotTrickGenerator.canonicalize(inputDraft).count >= 2 }

    private var sessionRemovalTitle: String {
        guard let session = controller.sessions.first(where: { $0.id == confirmingDeleteID }) else { return "Remove this session?" }
        return "Remove \(session.canonicalEmail)?"
    }

    private func generateFromDraft() {
        guard isInputValid else { return }
        controller.addSession(localPart: inputDraft)
        inputDraft = ""
        searchQuery = ""
    }

    private func filteredVariations(for session: DotTrickSession) -> [String] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? session.variations : session.variations.filter { $0.localizedStandardContains(query) }
    }

    private func copyToPasteboard(_ text: String, feedback: String) {
        if MacSystemActions.copyToPasteboard(text) { copyFeedback.show(feedback) }
    }

    private func copyAllVariations(for session: DotTrickSession) {
        let unused = session.variations.filter { !session.isUsed($0) }
        guard !unused.isEmpty else { return }
        copyToPasteboard(unused.joined(separator: "\n"), feedback: "__all_\(session.id.uuidString)")
    }
}

private struct EmailToolsSidebarRow: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let session: DotTrickSession
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        let palette = CodexTheme.palette(for: themeContext.preset)
        HStack(spacing: 4) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.canonicalEmail)
                        .font(ProfileManagerTypography.smallStrong)
                        .foregroundStyle(palette.dataValueText.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        if isSelected { Image(systemName: "checkmark").accessibilityHidden(true) }
                        Text("\(session.variationCount - session.usedCount) unused")
                    }
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(palette.supportText.color)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("email-tools.session.\(session.canonicalEmail)")
            .help(session.canonicalEmail)

            Menu {
                Button("Remove session…", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Label("Actions for \(session.canonicalEmail)", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(session.canonicalEmail)")
            .accessibilityIdentifier("email-tools.session-actions.\(session.canonicalEmail)")
            .help("Actions for \(session.canonicalEmail)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? palette.bg1.color : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct EmailToolsVariationRow: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let variation: String
    let isUsed: Bool
    let isCopied: Bool
    let toggleUsed: () -> Void
    let copy: () -> Void

    var body: some View {
        let palette = CodexTheme.palette(for: themeContext.preset)
        HStack(spacing: 8) {
            Toggle("Used", isOn: Binding(get: { isUsed }, set: { _ in toggleUsed() }))
                .toggleStyle(CodexCheckboxStyle())
                .labelsHidden()
                .frame(width: 28, height: 28)
                .accessibilityLabel("Used address: \(variation)")
                .accessibilityIdentifier("email-tools.used.\(variation)")
                .help(isUsed ? "Mark as unused" : "Mark as used")

            Text(highlightedVariation)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(isUsed ? palette.mutedText.color : palette.dataValueText.color)
                .strikethrough(isUsed, color: palette.mutedText.color)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(variation)

            Button(action: copy) {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .frame(width: 58)
            }
            .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.caption, foregroundColor: isCopied ? CodexTheme.successTextToken(preset: themeContext.preset).color : CodexTheme.utilityActionTextToken(preset: themeContext.preset).color, horizontalPadding: 8))
            .accessibilityLabel(isCopied ? "Address copied" : "Copy \(variation)")
            .accessibilityIdentifier("email-tools.copy.\(variation)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .background(CodexTheme.surfaceToken(for: .subtle, preset: themeContext.preset).color, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("email-tools.row.\(variation)")
    }

    private var highlightedVariation: AttributedString {
        var attributed = AttributedString(variation)
        if !isUsed, let dot = attributed.range(of: ".") {
            attributed[dot].foregroundColor = CodexTheme.utilityActionTextToken(preset: themeContext.preset).color
            attributed[dot].font = .system(size: 13, weight: .bold, design: .monospaced)
        }
        return attributed
    }
}
