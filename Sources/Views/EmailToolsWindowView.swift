import AppKit
import SwiftUI

struct EmailToolsWindowView: View {
    @Bindable var controller: DotTrickController
    @Environment(\.displayScale) private var displayScale
    @State private var windowChromeMetrics = WindowChromeMetrics()
    @State private var inputDraft = ""
    @State private var searchQuery = ""
    @State private var copiedVariation: String?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var confirmingDeleteID: UUID?

    var body: some View {
        let seamOverlap = 1 / max(displayScale, 1)

        VStack(spacing: 0) {
            AccountWindowTitleBarGlass(
                height: windowChromeMetrics.titleBarObscuredHeight,
                seamOverlap: seamOverlap
            )

            AccountWindowBodyShell(seamOverlap: seamOverlap) {
                VStack(alignment: .leading, spacing: CodexTheme.sectionSpacing) {
                    header

                    bodyContent
                }
                .padding(.top, CodexTheme.chromePadding)
                .padding(.horizontal, CodexTheme.chromePadding)
                .padding(.bottom, CodexTheme.chromePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(Color.clear)
        .overlay(alignment: .topLeading) {
            WindowChromeMetricsReader(metrics: $windowChromeMetrics)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .codexThemeRefreshScope()
        .onDisappear {
            resetCopyFeedback()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CodexPlusBar")
                    .font(ProfileManagerTypography.micro)
                    .foregroundStyle(CodexTheme.supportText)
                    .kerning(1.4)

                Text("Email Tools")
                    .font(ProfileManagerTypography.title)
                    .foregroundStyle(CodexTheme.primaryText)

                Text(headerMetaText)
                    .font(ProfileManagerTypography.body)
                    .foregroundStyle(CodexTheme.mutedText)
                    .lineLimit(2)
            }

            // Inline email input bar
            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CodexTheme.mutedText)

                TextField("username", text: $inputDraft)
                    .textFieldStyle(.plain)
                    .font(ProfileManagerTypography.body)
                    .foregroundStyle(CodexTheme.primaryText)
                    .onSubmit(generateFromDraft)

                Text("@gmail.com")
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(CodexTheme.mutedText)

                Button("Generate") {
                    generateFromDraft()
                }
                .buttonStyle(EmailToolsPrimaryButtonStyle())
                .disabled(isInputValid == false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                            .stroke(
                                isInputValid
                                    ? CodexTheme.warmBorder
                                    : CodexTheme.surfaceBorder(for: .subtle),
                                lineWidth: 1
                            )
                    )
            )
        }
    }

    private var headerMetaText: String {
        let count = controller.sessions.count
        if count == 0 {
            return "Generate Gmail dot trick variations"
        }

        return count == 1 ? "1 saved session" : "\(count) saved sessions"
    }

    // MARK: - Body

    private var bodyContent: some View {
        HStack(alignment: .top, spacing: CodexTheme.contentSpacing) {
            sidebar
                .frame(width: 260, alignment: .topLeading)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        CodexCard(tier: .regular) {
            VStack(alignment: .leading, spacing: 12) {
                if controller.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No sessions yet")
                            .font(ProfileManagerTypography.small)
                            .foregroundStyle(CodexTheme.mutedText)

                        Text("Enter a Gmail username above to get started.")
                            .font(ProfileManagerTypography.caption)
                            .foregroundStyle(CodexTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Sessions")
                        .font(ProfileManagerTypography.caption)
                        .foregroundStyle(CodexTheme.mutedText)

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(controller.sessions) { session in
                                EmailToolsSidebarRow(
                                    session: session,
                                    isSelected: session.id == controller.selectedSessionID,
                                    isConfirmingDelete: confirmingDeleteID == session.id,
                                    onSelect: {
                                        controller.selectSession(id: session.id)
                                        searchQuery = ""
                                    },
                                    onDelete: {
                                        confirmingDeleteID = session.id
                                    },
                                    onConfirmDelete: {
                                        controller.removeSession(id: session.id)
                                        confirmingDeleteID = nil
                                    },
                                    onCancelDelete: {
                                        confirmingDeleteID = nil
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let session = controller.selectedSession {
            variationList(for: session)
        } else {
            emptyDetailState
        }
    }

    private var emptyDetailState: some View {
        CodexCard(tier: .strong) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Gmail Dot Trick")
                    .font(ProfileManagerTypography.bodyStrong)
                    .foregroundStyle(CodexTheme.primaryText)

                Text("Gmail ignores dots in the local part of your email. Enter a username in the sidebar and click Generate to see all single-dot address variations.")
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func variationList(for session: DotTrickSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Detail header card
            CodexCard(tier: .strong, accent: CodexTheme.accentAqua) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "envelope.badge.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CodexTheme.accentAqua)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.canonicalEmail)
                                .font(ProfileManagerTypography.bodyStrong)
                                .foregroundStyle(CodexTheme.primaryText)

                            HStack(spacing: 0) {
                                Text("\(session.variationCount) single-dot variation\(session.variationCount == 1 ? "" : "s")")
                                    .font(ProfileManagerTypography.caption)
                                    .foregroundStyle(CodexTheme.mutedText)

                                if session.usedCount > 0 {
                                    Text(" · \(session.usedCount) used")
                                        .font(ProfileManagerTypography.caption)
                                        .foregroundStyle(CodexTheme.accentRed)
                                }
                            }
                        }

                        Spacer(minLength: 0)

                        Button {
                            copyAllVariations(for: session)
                        } label: {
                            let marker = "__all_\(session.id.uuidString)"
                            let isCopied = copiedVariation == marker
                            let hasUsed = session.usedCount > 0
                            Label(
                                isCopied
                                    ? (hasUsed ? "Copied unused" : "Copied all")
                                    : (hasUsed ? "Copy unused" : "Copy all"),
                                systemImage: isCopied ? "checkmark" : "doc.on.doc.fill"
                            )
                        }
                        .buttonStyle(EmailToolsSecondaryButtonStyle())
                        .help(session.usedCount > 0 ? "Copies only variations not marked as used" : "Copy all variations")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Search bar
            if session.variationCount > 6 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CodexTheme.mutedText)

                    TextField("Filter variations…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.primaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                        .fill(CodexTheme.surfaceFill(for: .subtle))
                        .overlay(
                            RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                                .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                        )
                )
            }

            // Count label
            let filtered = filteredVariations(for: session)
            if searchQuery.isEmpty == false {
                Text("\(filtered.count) of \(session.variationCount) variations")
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(CodexTheme.supportText)
            }

            // Variation list
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { index, variation in
                        EmailToolsVariationRow(
                            variation: variation,
                            index: index + 1,
                            isUsed: session.isUsed(variation),
                            isCopied: copiedVariation == variation,
                            onToggleUsed: {
                                controller.toggleUsed(variation: variation, inSession: session.id)
                            },
                            onCopy: {
                                copyVariation(variation)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Helpers

    private var isInputValid: Bool {
        DotTrickGenerator.canonicalize(inputDraft).count >= 2
    }

    private func generateFromDraft() {
        guard isInputValid else { return }
        controller.addSession(localPart: inputDraft)
        inputDraft = ""
        searchQuery = ""
    }

    private func filteredVariations(for session: DotTrickSession) -> [String] {
        let all = session.variations
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.isEmpty == false else {
            return all
        }

        return all.filter { $0.lowercased().contains(query) }
    }

    private func copyVariation(_ variation: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(variation, forType: .string)

        copiedVariation = variation
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard Task.isCancelled == false, copiedVariation == variation else {
                return
            }

            copiedVariation = nil
            copyResetTask = nil
        }
    }

    private func copyAllVariations(for session: DotTrickSession) {
        // Copy only unused variations when some are marked as used.
        let toCopy = session.variations.filter { session.isUsed($0) == false }
        guard toCopy.isEmpty == false else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(toCopy.joined(separator: "\n"), forType: .string)

        let marker = "__all_\(session.id.uuidString)"
        copiedVariation = marker
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard Task.isCancelled == false, copiedVariation == marker else {
                return
            }

            copiedVariation = nil
            copyResetTask = nil
        }
    }

    private func resetCopyFeedback() {
        copyResetTask?.cancel()
        copyResetTask = nil
        copiedVariation = nil
    }
}

// MARK: - Sidebar Row

private struct EmailToolsSidebarRow: View {
    let session: DotTrickSession
    let isSelected: Bool
    let isConfirmingDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onConfirmDelete: () -> Void
    let onCancelDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.canonicalEmail)
                            .font(ProfileManagerTypography.smallStrong)
                            .foregroundStyle(CodexTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 0) {
                            Text("\(session.variationCount) variation\(session.variationCount == 1 ? "" : "s")")
                                .font(ProfileManagerTypography.caption)
                                .foregroundStyle(CodexTheme.mutedText)

                            if session.usedCount > 0 {
                                Text(" · \(session.usedCount) used")
                                    .font(ProfileManagerTypography.caption)
                                    .foregroundStyle(CodexTheme.accentRed)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isConfirmingDelete == false {
                        Button(action: onDelete) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(CodexTheme.mutedText)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .opacity(0.7)
                        .help("Remove session")
                    }
                }

                if isConfirmingDelete {
                    HStack(spacing: 6) {
                        Text("Delete?")
                            .font(ProfileManagerTypography.caption)
                            .foregroundStyle(CodexTheme.accentRed)

                        Spacer(minLength: 0)

                        Button("Yes") {
                            onConfirmDelete()
                        }
                        .buttonStyle(EmailToolsDangerButtonStyle())

                        Button("No") {
                            onCancelDelete()
                        }
                        .buttonStyle(EmailToolsQuietButtonStyle())
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                .fill(isSelected ? CodexTheme.surfaceFill(for: .strong) : CodexTheme.surfaceFill(for: .nested))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                        .stroke(
                            isSelected
                                ? CodexTheme.accentAqua.opacity(0.35)
                                : CodexTheme.surfaceBorder(for: .nested),
                            lineWidth: 1
                        )
                )
        )
    }
}

// MARK: - Variation Row

private struct EmailToolsVariationRow: View {
    let variation: String
    let index: Int
    let isUsed: Bool
    let isCopied: Bool
    let onToggleUsed: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(index).")
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.mutedText)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)

            // Used toggle button
            Button(action: onToggleUsed) {
                Image(systemName: isUsed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: isUsed ? .medium : .regular))
                    .foregroundStyle(isUsed ? CodexTheme.accentRed : CodexTheme.mutedText)
            }
            .buttonStyle(.plain)
            .opacity(isUsed ? 1 : (isHovering ? 0.7 : 0.22))
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.2), value: isUsed)
            .help(isUsed ? "Unmark as used" : "Mark as used")
            .accessibilityLabel(isUsed ? "Marked as used" : "Mark as used")

            // Email text with optional strikethrough
            Text(highlightedVariation)
                .font(.codexUtility(size: 14, weight: .regular, relativeTo: .body))
                .foregroundStyle(isUsed ? CodexTheme.mutedText : CodexTheme.primaryText)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if isUsed {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(CodexTheme.accentRed)
                                .frame(width: proxy.size.width, height: 1.5)
                                .offset(y: proxy.size.height / 2)
                        }
                        .allowsHitTesting(false)
                    }
                }

            if isUsed == false {
                Button(action: onCopy) {
                    HStack(spacing: 5) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))

                        Text(isCopied ? "Copied" : "Copy")
                            .font(ProfileManagerTypography.caption)
                    }
                    .foregroundStyle(isCopied ? CodexTheme.accentGreen : CodexTheme.primaryText)
                }
                .buttonStyle(EmailToolsCopyButtonStyle(isCopied: isCopied))
                .disabled(isCopied)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .opacity(isUsed ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .nested))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                        .stroke(CodexTheme.surfaceBorder(for: .nested), lineWidth: 1)
                )
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.2), value: isUsed)
    }

    private var highlightedVariation: AttributedString {
        var attributed = AttributedString(variation)

        if isUsed {
            // No dot highlight for used rows — keep them visually quiet.
            return attributed
        }

        // Highlight the dot in a different color.
        if let dotRange = attributed.range(of: ".") {
            attributed[dotRange].foregroundColor = CodexTheme.accentAqua
            attributed[dotRange].font = .codexUtility(size: 14, weight: .bold, relativeTo: .body)
        }

        return attributed
    }
}

// MARK: - Button Styles

private struct EmailToolsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(CodexTheme.accentInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.accentGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .shadow(color: CodexTheme.accentOrange.opacity(0.20), radius: 12, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.46)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct EmailToolsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(CodexTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .fill(CodexTheme.surfaceSheen(for: .subtle))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.46)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct EmailToolsCopyButtonStyle: ButtonStyle {
    let isCopied: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isCopied
                            ? CodexTheme.accentGreen.opacity(0.12)
                            : CodexTheme.surfaceFill(for: .subtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                isCopied
                                    ? CodexTheme.accentGreen.opacity(0.28)
                                    : CodexTheme.surfaceBorder(for: .subtle),
                                lineWidth: 1
                            )
                    )
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct EmailToolsDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.caption)
            .foregroundStyle(CodexTheme.accentRed)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(CodexTheme.accentRed.opacity(configuration.isPressed ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(CodexTheme.accentRed.opacity(0.24), lineWidth: 1)
            )
    }
}

private struct EmailToolsQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.caption)
            .foregroundStyle(CodexTheme.mutedText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle).opacity(configuration.isPressed ? 0.98 : 0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
            )
    }
}
