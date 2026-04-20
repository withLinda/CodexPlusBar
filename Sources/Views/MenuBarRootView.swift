import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @Bindable var controller: PlusProfileController
    @AppStorage(MenuBarProfilePreference.preferredProfileIDKey) private var preferredProfileIDStorage = ""
    let currentTime: AppMinuteClock
    let openManagerWindow: @MainActor (UUID?) -> Void

    init(
        controller: PlusProfileController,
        currentTime: AppMinuteClock,
        userDefaults: UserDefaults = .standard,
        openManagerWindow: @escaping @MainActor (UUID?) -> Void
    ) {
        self.controller = controller
        self.currentTime = currentTime
        self.openManagerWindow = openManagerWindow
        _preferredProfileIDStorage = AppStorage(
            wrappedValue: "",
            MenuBarProfilePreference.preferredProfileIDKey,
            store: userDefaults
        )
    }

    var body: some View {
        let panelContentWidth = MenuBarPanelMetrics.contentWidth

        CodexShell(role: .panel, padding: MenuBarPanelMetrics.innerPadding) {
            VStack(alignment: .leading, spacing: CodexTheme.sectionSpacing) {
                header

                if let bannerMessage = controller.statusMessage {
                    CodexStatusBanner(
                        title: controller.dashboardStatus.title,
                        message: bannerMessage,
                        tone: controller.dashboardStatus.tone,
                        symbolName: controller.dashboardStatus.symbolName
                    )
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: CodexTheme.sectionSpacing) {
                        content
                    }
                    .frame(width: panelContentWidth, alignment: .leading)
                }
                .frame(width: panelContentWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)

                footer
            }
            .frame(width: panelContentWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(MenuBarPanelMetrics.chromeInset)
        .frame(
            width: MenuBarPanelMetrics.width,
            height: MenuBarPanelMetrics.height,
            alignment: .topLeading
        )
        .onAppear(perform: clearStalePreferredProfileID)
        .onChange(of: controller.profiles.map(\.id)) { _, _ in
            clearStalePreferredProfileID()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CodexPlusBar")
                    .font(.codexMicro)
                    .foregroundStyle(CodexTheme.supportText)
                    .kerning(1.2)

                Text("Profiles")
                    .font(.codexTitle)
                    .foregroundStyle(CodexTheme.primaryText)

                Text(headerMetaText)
                    .font(.codexSmall)
                    .foregroundStyle(CodexTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                CodexStatusBadge(
                    title: controller.dashboardStatus.title,
                    tone: controller.dashboardStatus.tone
                )

                if controller.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CodexTheme.accentOrange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if controller.profiles.isEmpty {
            CodexCard(tier: .strong, accent: controller.dashboardStatus.tone.foregroundColor) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add your first profile")
                        .font(.codexBodyStrong)
                        .foregroundStyle(CodexTheme.primaryText)

                    Text("Each profile keeps its own ChatGPT cookies, so you only need to sign in once per email account.")
                        .font(.codexSmall)
                        .foregroundStyle(CodexTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open manager") {
                        openManagerWindow(nil)
                    }
                    .buttonStyle(CodexPrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(controller.profiles) { snapshot in
                MenuBarProfileCard(
                    snapshot: snapshot,
                    referenceDate: currentTime.now,
                    isPinned: snapshot.id == storedPinnedProfileID,
                    openManagerWindow: {
                        openManagerWindow(snapshot.id)
                    },
                    copyProfileLabel: {
                        copyProfileLabel(snapshot.label)
                    },
                    openEmailLink: {
                        openEmailLink(for: snapshot.profile)
                    },
                    canOpenEmailLink: snapshot.profile.resolvedEmailLinkURL != nil,
                    pinProfile: {
                        setPinnedProfile(snapshot.id)
                    }
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            CodexIconButton(
                symbolName: "arrow.clockwise",
                helpText: "Refresh all profiles",
                tone: .primary,
                isDisabled: controller.isRefreshing,
                action: refreshAll
            )

            CodexIconButton(
                symbolName: "rectangle.on.rectangle",
                helpText: "Open manager window",
                tone: .secondary,
                action: {
                    openManagerWindow(preferredManagerProfileID)
                }
            )

            CodexIconButton(
                symbolName: "power",
                helpText: "Quit CodexPlusBar",
                tone: .quiet,
                action: quitApp
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerMetaText: String {
        let count = controller.profiles.count
        let countLabel = count == 1 ? "1 profile" : "\(count) profiles"

        if let updatedAt = controller.profiles.compactMap(\.lastRefreshAt).max(),
           let updatedText = DisplayFormatter.updatedText(updatedAt, referenceDate: currentTime.now) {
            return "\(updatedText) · \(countLabel)"
        }

        return count == 0 ? "No saved profiles yet" : countLabel
    }

    private func refreshAll() {
        Task {
            await controller.refreshAll()
        }
    }

    private var storedPinnedProfileID: UUID? {
        MenuBarProfilePreference.normalizedProfileID(from: preferredProfileIDStorage)
    }

    private var currentPinnedProfileID: UUID? {
        guard let storedPinnedProfileID else {
            return nil
        }

        return controller.profiles.first(where: { $0.id == storedPinnedProfileID })?.id
    }

    private var preferredManagerProfileID: UUID? {
        currentPinnedProfileID ?? controller.selectedProfileID ?? controller.profiles.first?.id
    }

    private func setPinnedProfile(_ profileID: UUID) {
        preferredProfileIDStorage = MenuBarProfilePreference.storedValue(for: profileID)
    }

    private func copyProfileLabel(_ label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(label, forType: .string)
    }

    private func openEmailLink(for profile: PlusProfile) {
        guard let url = profile.resolvedEmailLinkURL else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func clearStalePreferredProfileID() {
        let trimmed = preferredProfileIDStorage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return
        }

        guard let storedPinnedProfileID,
              controller.profiles.contains(where: { $0.id == storedPinnedProfileID }) else {
            preferredProfileIDStorage = ""
            return
        }
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

struct MenuBarStatusLabel: View {
    let controller: PlusProfileController
    @AppStorage(MenuBarProfilePreference.preferredProfileIDKey) private var preferredProfileIDStorage = ""
    let currentTime: AppMinuteClock

    var body: some View {
        let labelText = controller.statusBarText(
            preferredProfileID: MenuBarProfilePreference.normalizedProfileID(from: preferredProfileIDStorage),
            referenceDate: currentTime.now
        )
        let labelColor = statusLabelColor

        HStack(spacing: 5) {
            Image(systemName: controller.statusBarSymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(labelColor)

            Text(labelText)
                .font(.codexMenuBarLabel)
                .lineLimit(1)
                .monospacedDigit()
                .foregroundStyle(labelColor)
        }
        .accessibilityLabel("CodexPlusBar \(labelText)")
    }

    private var statusLabelColor: Color {
        if controller.dashboardStatus == .ready,
           let urgent = controller.readyProfiles.min(by: {
               ($0.usage?.fiveHourRemainingPercent ?? 101) < ($1.usage?.fiveHourRemainingPercent ?? 101)
           }),
           let remaining = urgent.usage?.fiveHourRemainingPercent {
            return remaining <= 20
                ? CodexTheme.accentOrange
                : CodexTheme.accentGreen
        }

        return controller.dashboardStatus.tone.foregroundColor
    }
}

private struct MenuBarProfileCard: View {
    let snapshot: PlusProfileSnapshot
    let referenceDate: Date
    let isPinned: Bool
    let openManagerWindow: () -> Void
    let copyProfileLabel: () -> Void
    let openEmailLink: () -> Void
    let canOpenEmailLink: Bool
    let pinProfile: () -> Void

    var body: some View {
        CodexCard(tier: snapshot.state == .needsLogin ? .strong : .regular, accent: accentColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .center, spacing: 8) {
                            Button(action: openManagerWindow) {
                                Text(snapshot.label)
                                    .font(.codexBodyStrong)
                                    .foregroundStyle(CodexTheme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 6) {
                                MenuBarInlineActionButton(
                                    symbolName: "doc.on.doc",
                                    helpText: "Copy profile label",
                                    action: copyProfileLabel
                                )

                                MenuBarInlineActionButton(
                                    symbolName: "arrow.up.forward.square",
                                    helpText: canOpenEmailLink
                                        ? "Open email link"
                                        : "Add an email link in the manager to open it here",
                                    isDisabled: canOpenEmailLink == false,
                                    action: openEmailLink
                                )
                            }
                        }

                        if let note = snapshot.note {
                            Button(action: openManagerWindow) {
                                Text(note)
                                    .font(.codexCaption)
                                    .foregroundStyle(CodexTheme.supportText)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 8) {
                        CodexStatusBadge(
                            title: snapshot.state.title,
                            tone: snapshot.state.tone
                        )

                        if snapshot.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(CodexTheme.accentOrange)
                        }

                        MenuBarPinnedProfileButton(
                            isPinned: isPinned,
                            action: pinProfile
                        )
                    }
                }

                Button(action: openManagerWindow) {
                    detailContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: CodexTheme.sectionCornerRadius, style: .continuous))
        .contextMenu {
            Button(isPinned ? "Current" : "Show on top") {
                pinProfile()
            }
            .disabled(isPinned)
        }
    }

    private var accentColor: Color? {
        guard let remaining = snapshot.usage?.fiveHourRemainingPercent else {
            return snapshot.state == .ready ? nil : snapshot.state.tone.foregroundColor
        }

        if remaining <= 20 {
            return CodexTheme.accentOrange
        }

        return remaining <= 40 ? CodexTheme.accentYellow : CodexTheme.accentGreen
    }

    private var emptyMessage: String {
        switch snapshot.state {
        case .idle:
            return "Open the manager to sign in or refresh this profile."
        case .loading:
            return "Loading live usage."
        case .ready:
            return "Usage is ready."
        case .needsLogin:
            return "Sign in again in the manager window."
        case .failed:
            return "Refresh this profile in the manager window."
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let usage = snapshot.usage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProfileMetricPill(
                        title: "5H",
                        value: snapshot.fiveHourText,
                        tone: snapshot.state.tone
                    )

                    ProfileMetricPill(
                        title: "7D",
                        value: snapshot.sevenDayText,
                        tone: .neutral
                    )
                }

                Text(resetSummary(for: usage))
                    .font(.codexCaption)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(snapshot.statusMessage ?? emptyMessage)
                .font(.codexSmall)
                .foregroundStyle(snapshot.state.tone.foregroundColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resetSummary(for usage: PlusProfileUsage) -> String {
        var parts = ["5H resets in \(usage.primaryWindow.resetDescription(referenceDate: referenceDate))"]

        if let secondaryWindow = usage.secondaryWindow {
            parts.append("7D resets in \(secondaryWindow.resetDescription(referenceDate: referenceDate))")
        }

        return parts.joined(separator: " · ")
    }
}

private struct MenuBarInlineActionButton: View {
    let symbolName: String
    let helpText: String
    let isDisabled: Bool
    let action: () -> Void

    init(
        symbolName: String,
        helpText: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.helpText = helpText
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? CodexTheme.quietText : CodexTheme.primaryText)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                )
        )
        .opacity(isDisabled ? 0.52 : 1)
        .accessibilityLabel(helpText)
        .help(helpText)
        .disabled(isDisabled)
    }
}

private struct MenuBarPinnedProfileButton: View {
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        Button(isPinned ? "Current" : "Show on top") {
            action()
        }
        .buttonStyle(.plain)
        .font(.codexMicro)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        )
        .help(
            isPinned
                ? "This profile already drives the top menu bar summary."
                : "Show this profile in the top menu bar summary."
        )
        .disabled(isPinned)
    }

    private var foregroundColor: Color {
        isPinned ? CodexTheme.primaryText : CodexTheme.accentOrange
    }

    private var backgroundColor: Color {
        isPinned ? CodexTheme.surfaceFill(for: .subtle) : CodexTheme.accentOrange.opacity(0.10)
    }

    private var borderColor: Color {
        isPinned ? CodexTheme.surfaceBorder(for: .subtle) : CodexTheme.accentOrange.opacity(0.24)
    }
}

private struct ProfileMetricPill: View {
    let title: String
    let value: String
    let tone: CodexStatusTone

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.codexCaption)
                .foregroundStyle(CodexTheme.supportText)

            Text(value)
                .font(.codexSmallStrong)
                .foregroundStyle(tone == .neutral ? CodexTheme.primaryText : tone.foregroundColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .nested))
                .overlay {
                    RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                        .stroke(CodexTheme.surfaceBorder(for: .nested), lineWidth: 1)
                }
        )
    }
}

enum MenuBarPanelMetrics {
    static let width: CGFloat = 484
    static let height: CGFloat = 560
    static let chromeInset: CGFloat = 10
    static let innerPadding: CGFloat = 20
    static let contentWidth = width - (chromeInset * 2) - (innerPadding * 2)
}
