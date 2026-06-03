import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @Bindable var controller: PlusProfileController
    @AppStorage(MenuBarProfilePreference.preferredProfileIDKey) private var preferredProfileIDStorage = ""
    @AppStorage(MenuBarPanelTextScalePreference.textScaleKey) private var panelTextScaleStorage = MenuBarPanelTextScalePreference.defaultScale
    @State private var tagFilter = ProfileTagFilter()
    let currentTime: AppMinuteClock
    let openManagerWindow: @MainActor (UUID?) -> Void
    let openEmailToolsWindow: @MainActor () -> Void

    init(
        controller: PlusProfileController,
        currentTime: AppMinuteClock,
        userDefaults: UserDefaults = .standard,
        openManagerWindow: @escaping @MainActor (UUID?) -> Void,
        openEmailToolsWindow: @escaping @MainActor () -> Void
    ) {
        self.controller = controller
        self.currentTime = currentTime
        self.openManagerWindow = openManagerWindow
        self.openEmailToolsWindow = openEmailToolsWindow
        _preferredProfileIDStorage = AppStorage(
            wrappedValue: "",
            MenuBarProfilePreference.preferredProfileIDKey,
            store: userDefaults
        )
        _panelTextScaleStorage = AppStorage(
            wrappedValue: MenuBarPanelTextScalePreference.defaultScale,
            MenuBarPanelTextScalePreference.textScaleKey,
            store: userDefaults
        )
    }

    var body: some View {
        let panelContentWidth = MenuBarPanelMetrics.contentWidth

        CodexShell(role: .panel, padding: MenuBarPanelMetrics.innerPadding) {
            VStack(alignment: .leading, spacing: MenuBarPanelMetrics.stackSpacing) {
                header

                if controller.profiles.isEmpty == false {
                    ProfileTagFilterBar(
                        presentation: tagFilterPresentation,
                        textScale: panelTextScale,
                        clearFilter: clearTagFilter,
                        toggleTag: toggleTagFilter
                    )
                }

                if let bannerMessage = controller.statusMessage {
                    CodexStatusBanner(
                        title: controller.dashboardStatus.title,
                        message: bannerMessage,
                        tone: controller.dashboardStatus.tone,
                        symbolName: controller.dashboardStatus.symbolName
                    )
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: MenuBarPanelMetrics.rowSpacing) {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text("Profiles")
                    .font(.codexSans(
                        size: 18 * CGFloat(panelTextScale),
                        weight: .semibold,
                        relativeTo: .headline
                    ))
                    .foregroundStyle(CodexTheme.primaryText)

                Spacer(minLength: 0)

                MenuBarZoomControls(
                    textScale: panelTextScale,
                    canZoomOut: panelTextScale > MenuBarPanelTextScalePreference.minimumScale,
                    canZoomIn: panelTextScale < MenuBarPanelTextScalePreference.maximumScale,
                    zoomOut: zoomPanelOut,
                    zoomIn: zoomPanelIn
                )

                CodexStatusBadge(
                    title: controller.dashboardStatus.title,
                    tone: controller.dashboardStatus.tone
                )

                if controller.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(CodexTheme.accentOrange)
                }
            }

            Text(headerMetaText)
                .font(ProfileManagerTypography.small(scale: panelTextScale))
                .foregroundStyle(CodexTheme.mutedText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if controller.profiles.isEmpty {
            CodexCard(tier: .strong, accent: controller.dashboardStatus.tone.foregroundColor) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add your first profile")
                        .font(ProfileManagerTypography.bodyStrong(scale: panelTextScale))
                        .foregroundStyle(CodexTheme.primaryText)

                    Text("Each profile uses its own Chrome sign-in, so you only need to sign in once per email account.")
                        .font(ProfileManagerTypography.small(scale: panelTextScale))
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
        } else if filteredProfiles.isEmpty {
            ProfileTagEmptyState(clearFilter: clearTagFilter)
        } else {
            ForEach(filteredProfiles) { snapshot in
                let isPinned = snapshot.id == storedPinnedProfileID

                MenuBarProfileRow(
                    snapshot: snapshot,
                    referenceDate: currentTime.now,
                    isPinned: isPinned,
                    textScale: panelTextScale,
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
                symbolName: "envelope.badge.fill",
                helpText: "Open email tools",
                tone: .secondary,
                action: {
                    openEmailToolsWindow()
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

    private var panelTextScale: Double {
        MenuBarPanelTextScalePreference.normalizedTextScale(panelTextScaleStorage)
    }

    private var headerMetaText: String {
        if let updatedAt = controller.profiles.compactMap(\.lastRefreshAt).max(),
           let updatedText = DisplayFormatter.updatedText(updatedAt, referenceDate: currentTime.now) {
            return "\(updatedText) · \(tagFilterPresentation.countText)"
        }

        return controller.profiles.isEmpty ? "No saved profiles yet" : tagFilterPresentation.countText
    }

    private var filteredProfiles: [PlusProfileSnapshot] {
        tagFilter.apply(to: controller.profiles)
    }

    private var profileTagCounts: ProfileTagCounts {
        ProfileTagCounts(snapshots: controller.profiles)
    }

    private var tagFilterPresentation: ProfileTagFilterBarPresentation {
        ProfileTagFilterBarPresentation(
            filter: tagFilter,
            shownCount: filteredProfiles.count,
            totalCount: controller.profiles.count,
            tagCounts: profileTagCounts
        )
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

    private func clearTagFilter() {
        tagFilter.clear()
    }

    private func toggleTagFilter(_ tag: PlusProfileTag) {
        tagFilter.toggle(tag)
    }

    private func zoomPanelIn() {
        panelTextScaleStorage = MenuBarPanelTextScalePreference.zoomedInValue(from: panelTextScale)
    }

    private func zoomPanelOut() {
        panelTextScaleStorage = MenuBarPanelTextScalePreference.zoomedOutValue(from: panelTextScale)
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

private struct MenuBarZoomControls: View {
    let textScale: Double
    let canZoomOut: Bool
    let canZoomIn: Bool
    let zoomOut: () -> Void
    let zoomIn: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            MenuBarZoomButton(
                title: "A-",
                helpText: "Zoom out menu bar panel",
                textScale: textScale,
                isDisabled: canZoomOut == false,
                action: zoomOut
            )

            MenuBarZoomButton(
                title: "A+",
                helpText: "Zoom in menu bar panel",
                textScale: textScale,
                isDisabled: canZoomIn == false,
                action: zoomIn
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar panel zoom")
    }
}

private struct MenuBarZoomButton: View {
    let title: String
    let helpText: String
    let textScale: Double
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ProfileManagerTypography.caption(scale: textScale))
                .monospacedDigit()
                .frame(minWidth: 30, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? CodexTheme.quietText : CodexTheme.primaryText)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                )
        )
        .opacity(isDisabled ? 0.46 : 1)
        .accessibilityLabel(helpText)
        .help(helpText)
        .disabled(isDisabled)
    }
}

struct MenuBarStatusLabel: View {
    let controller: PlusProfileController
    @AppStorage(MenuBarProfilePreference.preferredProfileIDKey) private var preferredProfileIDStorage = ""
    let currentTime: AppMinuteClock

    var body: some View {
        let content = controller.statusBarContent(
            preferredProfileID: MenuBarProfilePreference.normalizedProfileID(from: preferredProfileIDStorage),
            referenceDate: currentTime.now
        )
        let labelColor = statusLabelColor

        HStack(spacing: 5) {
            Image(systemName: controller.statusBarSymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(labelColor)

            if content.showsUsageSummary {
                Text(content.profileLabel)
                    .font(.codexMenuBarLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(labelColor)

                Image(systemName: "hourglass.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(labelColor)

                Text(content.fiveHourText)
                    .font(.codexMenuBarLabel)
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(labelColor)

                Image(systemName: "7.calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(labelColor)

                Text(content.sevenDayText)
                    .font(.codexMenuBarLabel)
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(labelColor)
            } else {
                Text(content.plainText)
                    .font(.codexMenuBarLabel)
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(labelColor)
            }
        }
        .accessibilityLabel("CodexPlusBar \(content.accessibilityText)")
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
    let textScale: Double
    let openManagerWindow: () -> Void
    let copyProfileLabel: () -> Void
    let openEmailLink: () -> Void
    let pinProfile: () -> Void

    var body: some View {
        ProfileSummaryRow(
            snapshot: snapshot,
            referenceDate: referenceDate,
            mode: .menuBar(isPinned: isPinned),
            textScale: textScale,
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
    static let innerPadding: CGFloat = 18
    static let stackSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let contentWidth = width - (chromeInset * 2) - (innerPadding * 2)
}
