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
                let isPinned = snapshot.id == storedPinnedProfileID

                MenuBarProfileRow(
                    snapshot: snapshot,
                    referenceDate: currentTime.now,
                    isPinned: isPinned,
                    openManagerWindow: {
                        openManagerWindow(snapshot.id)
                    },
                    copyProfileLabel: {
                        copyProfileLabel(snapshot.label)
                    },
                    openEmailLink: {
                        openEmailLink(for: snapshot.profile)
                    },
                    pinProfile: {
                        setPinnedProfile(snapshot.id)
                    }
                )
                .contextMenu {
                    Button(isPinned ? "Current" : "Show on top") {
                        setPinnedProfile(snapshot.id)
                    }
                    .disabled(isPinned)

                    Button("Copy profile label") {
                        copyProfileLabel(snapshot.label)
                    }

                    if snapshot.profile.resolvedEmailLinkURL != nil {
                        Button("Open email link") {
                            openEmailLink(for: snapshot.profile)
                        }
                    }

                    Button("Open manager") {
                        openManagerWindow(snapshot.id)
                    }
                }
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

private struct MenuBarProfileRow: View {
    let snapshot: PlusProfileSnapshot
    let referenceDate: Date
    let isPinned: Bool
    let openManagerWindow: () -> Void
    let copyProfileLabel: () -> Void
    let openEmailLink: () -> Void
    let pinProfile: () -> Void

    var body: some View {
        ProfileSummaryRow(
            snapshot: snapshot,
            referenceDate: referenceDate,
            mode: .menuBar(isPinned: isPinned),
            primaryAction: openManagerWindow,
            copyAction: copyProfileLabel,
            emailAction: openEmailLink,
            pinAction: pinProfile
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
