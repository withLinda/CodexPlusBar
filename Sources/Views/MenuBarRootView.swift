import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @Bindable var controller: PlusProfileController
    @Environment(\.openSettings) private var openSettings
    @AppStorage(MenuBarProfilePreference.preferredProfileIDKey) private var preferredProfileIDStorage = ""
    @AppStorage(MenuBarPanelTextScalePreference.textScaleKey) private var panelTextScaleStorage = MenuBarPanelTextScalePreference.defaultScale
    @State private var profileFilter = ProfileFilter()
    @State private var profileSearchQuery = ""
    @State private var isProfileSearchPresented = false
    let currentTime: AppMinuteClock
    let openManagerWindow: @MainActor (UUID?) -> Void
    let openEmailToolsWindow: @MainActor () -> Void
    let closePanel: @MainActor () -> Void

    init(
        controller: PlusProfileController,
        currentTime: AppMinuteClock,
        userDefaults: UserDefaults = .standard,
        openManagerWindow: @escaping @MainActor (UUID?) -> Void,
        openEmailToolsWindow: @escaping @MainActor () -> Void,
        closePanel: @escaping @MainActor () -> Void = {}
    ) {
        self.controller = controller
        self.currentTime = currentTime
        self.openManagerWindow = openManagerWindow
        self.openEmailToolsWindow = openEmailToolsWindow
        self.closePanel = closePanel
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
        let listPresentation = profileListPresentation

        CodexShell(role: .panel, padding: MenuBarPanelMetrics.innerPadding) {
            VStack(alignment: .leading, spacing: MenuBarPanelMetrics.stackSpacing) {
                header(listPresentation: listPresentation)

                if controller.profiles.isEmpty == false {
                    if isProfileSearchPresented {
                        ProfileSearchField(
                            text: $profileSearchQuery,
                            textScale: panelTextScale,
                            close: closeProfileSearch
                        )
                    }

                    ProfileFilterBar(
                        presentation: listPresentation.filterBar,
                        textScale: panelTextScale,
                        clearFilter: clearProfileFilter,
                        toggleFullLimit: toggleFullLimitFilter,
                        toggleTag: toggleProfileTagFilter
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

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: MenuBarPanelMetrics.rowSpacing) {
                        content(displayedProfiles: listPresentation.displayedProfiles)
                    }
                    .frame(width: panelContentWidth, alignment: .leading)
                }
                .scrollIndicators(.hidden)
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
            if controller.profiles.isEmpty {
                closeProfileSearch()
            }
        }
    }

    private func header(listPresentation: ProfileListPresentation) -> some View {
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

                if controller.profiles.isEmpty == false {
                    MenuBarSearchButton(
                        isActive: isProfileSearchPresented,
                        textScale: panelTextScale,
                        action: showProfileSearch
                    )
                }

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

            Text(headerMetaText(filterBar: listPresentation.filterBar))
                .font(ProfileManagerTypography.small(scale: panelTextScale))
                .foregroundStyle(CodexTheme.mutedText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(displayedProfiles: [PlusProfileSnapshot]) -> some View {
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
        } else if displayedProfiles.isEmpty,
                  ProfileSearch.normalizedQuery(profileSearchQuery).isEmpty == false {
            ProfileSearchEmptyState(
                query: profileSearchQuery,
                clearsFilter: profileFilter.isEmpty == false,
                textScale: panelTextScale,
                clear: clearSearchAndActiveFilters
            )
        } else if displayedProfiles.isEmpty {
            ProfileFilterEmptyState(clearFilter: clearProfileFilter)
        } else {
            ForEach(displayedProfiles) { snapshot in
                let isPinned = snapshot.id == storedPinnedProfileID

                MenuBarProfileRow(
                    snapshot: snapshot,
                    referenceDate: currentTime.now,
                    isPinned: isPinned,
                    textScale: panelTextScale,
                    searchPhoneNumber: ProfileSearch.matchingPhoneNumber(
                        in: snapshot,
                        query: profileSearchQuery
                    ),
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
            ForEach(MenuBarFooterAction.allCases) { footerAction in
                CodexIconButton(
                    symbolName: footerAction.symbolName,
                    helpText: footerAction.helpText,
                    tone: footerAction.tone,
                    isDisabled: footerAction == .refreshAll && controller.isRefreshing,
                    action: {
                        performFooterAction(footerAction)
                    }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelTextScale: Double {
        MenuBarPanelTextScalePreference.normalizedTextScale(panelTextScaleStorage)
    }

    private func headerMetaText(filterBar: ProfileFilterBarPresentation) -> String {
        if let updatedAt = controller.profiles.compactMap(\.lastRefreshAt).max(),
           let updatedText = DisplayFormatter.updatedText(updatedAt, referenceDate: currentTime.now) {
            return "\(updatedText) · \(filterBar.countText)"
        }

        return controller.profiles.isEmpty ? "No saved profiles yet" : filterBar.countText
    }

    func displayProfiles(for filter: ProfileFilter) -> [PlusProfileSnapshot] {
        displayProfiles(for: filter, query: "")
    }

    func displayProfiles(
        for filter: ProfileFilter,
        query: String
    ) -> [PlusProfileSnapshot] {
        ProfileListPresentation(
            profiles: controller.profiles,
            filter: filter,
            query: query
        ).displayedProfiles
    }

    private var profileListPresentation: ProfileListPresentation {
        ProfileListPresentation(
            profiles: controller.profiles,
            filter: profileFilter,
            query: profileSearchQuery
        )
    }

    private func refreshAll() {
        Task {
            await controller.refreshAll()
        }
    }

    private func performFooterAction(_ footerAction: MenuBarFooterAction) {
        switch footerAction {
        case .refreshAll:
            refreshAll()
        case .openManager:
            openManagerWindow(preferredManagerProfileID)
        case .openEmailTools:
            openEmailToolsWindow()
        case .openThemeSettings:
            closePanel()
            openSettings()
        case .quit:
            quitApp()
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

    private func clearProfileFilter() {
        profileFilter.clear()
    }

    private func clearSearchAndActiveFilters() {
        profileSearchQuery = ""
        profileFilter.clear()
    }

    private func showProfileSearch() {
        isProfileSearchPresented = true
    }

    private func closeProfileSearch() {
        profileSearchQuery = ""
        isProfileSearchPresented = false
    }

    private func toggleFullLimitFilter() {
        profileFilter.toggleFullFiveHourLimit()
    }

    private func toggleProfileTagFilter(_ tag: PlusProfileTag) {
        profileFilter.toggle(tag)
    }

    private func zoomPanelIn() {
        panelTextScaleStorage = MenuBarPanelTextScalePreference.zoomedInValue(from: panelTextScale)
    }

    private func zoomPanelOut() {
        panelTextScaleStorage = MenuBarPanelTextScalePreference.zoomedOutValue(from: panelTextScale)
    }

    private func copyProfileLabel(_ label: String) {
        MacSystemActions.copyToPasteboard(label)
    }

    private func openEmailLink(for profile: PlusProfile) {
        MacSystemActions.open(profile.resolvedEmailLinkURL)
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

enum MenuBarFooterAction: CaseIterable, Identifiable {
    case refreshAll
    case openManager
    case openEmailTools
    case openThemeSettings
    case quit

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .refreshAll:
            return "arrow.clockwise"
        case .openManager:
            return "rectangle.on.rectangle"
        case .openEmailTools:
            return "envelope.badge.fill"
        case .openThemeSettings:
            return "gearshape"
        case .quit:
            return "power"
        }
    }

    var helpText: String {
        switch self {
        case .refreshAll:
            return "Refresh all profiles"
        case .openManager:
            return "Open manager window"
        case .openEmailTools:
            return "Open email tools"
        case .openThemeSettings:
            return "Open theme settings"
        case .quit:
            return "Quit CodexPlusBar"
        }
    }

    var tone: CodexControlTone {
        switch self {
        case .refreshAll:
            return .primary
        case .openManager, .openEmailTools, .openThemeSettings:
            return .secondary
        case .quit:
            return .quiet
        }
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

private struct MenuBarSearchButton: View {
    let isActive: Bool
    let textScale: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12 * CGFloat(textScale), weight: .semibold))
                .frame(minWidth: 30, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? CodexTheme.searchAction : CodexTheme.primaryText)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isActive
                        ? CodexTheme.searchFieldFill
                        : CodexTheme.surfaceFill(for: .subtle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isActive
                                ? CodexTheme.searchFocusBorder
                                : CodexTheme.surfaceBorder(for: .subtle),
                            lineWidth: 1
                        )
                )
        )
        .accessibilityLabel("Search profiles")
        .help("Search profiles")
        .opacity(isActive ? 0 : 1)
        .allowsHitTesting(isActive == false)
        .accessibilityHidden(isActive)
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
        .foregroundStyle(isDisabled ? CodexTheme.disabledText : CodexTheme.primaryText)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
                )
        )
        .accessibilityLabel(helpText)
        .help(helpText)
        .disabled(isDisabled)
    }
}

private struct MenuBarProfileRow: View {
    let snapshot: PlusProfileSnapshot
    let referenceDate: Date
    let isPinned: Bool
    let textScale: Double
    let searchPhoneNumber: String?
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
            searchPhoneNumber: searchPhoneNumber,
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
