import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CodexThemeSettings.Keys.appearanceMode) private var themeAppearance = CodexThemeSettings.defaultAppearanceMode
    @AppStorage(CodexThemeSettings.Keys.contrast) private var themeContrast = CodexThemeSettings.defaultContrast
    @Bindable var controller: PlusProfileController
    @Environment(\.openSettings) private var openSettings
    @AppStorage(MenuBarProfilePreference.preferredProfileIDKey) private var preferredProfileIDStorage = ""
    @AppStorage(MenuBarPanelTextScalePreference.textScaleKey) private var panelTextScaleStorage = MenuBarPanelTextScalePreference.defaultScale
    @AppStorage(ProfileDisplayOrderPreference.orderKey) private var profileDisplayOrder = ProfileDisplayOrderPreference.defaultOrder
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
        _profileDisplayOrder = AppStorage(
            wrappedValue: ProfileDisplayOrderPreference.defaultOrder,
            ProfileDisplayOrderPreference.orderKey,
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

                    ProfileListControlsBar(
                        filterPresentation: listPresentation.filterBar,
                        displayOrder: $profileDisplayOrder,
                        textScale: panelTextScale,
                        clearFilter: clearProfileFilter,
                        toggleLimit: toggleLimitFilter,
                        toggleTag: toggleProfileTagFilter,
                        toggleProvider: toggleProfileProviderFilter
                    )
                }

                if let status = controller.openChamberActionStatus {
                    CodexStatusBanner(
                        title: "OpenChamber OpenAI",
                        message: status.message,
                        tone: status.tone,
                        symbolName: "bubble.left.and.bubble.right"
                    )
                } else if let bannerMessage = controller.statusMessage {
                    CodexStatusBanner(
                        title: controller.dashboardStatus.title,
                        message: bannerMessage,
                        tone: controller.dashboardStatus.tone,
                        symbolName: controller.dashboardStatus.symbolName
                    )
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: MenuBarPanelMetrics.rowSpacing) {
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
        .tint(CodexTheme.searchActionToken(preset: CodexThemeRefreshContext(appearanceMode: themeAppearance, contrast: themeContrast, systemVariant: colorScheme == .dark ? .dark : .light).preset).color)
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

                Button(action: refreshAll) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(CodexQuietButtonStyle(horizontalPadding: 0, verticalPadding: 0))
                .disabled(controller.isRefreshing)
                .keyboardShortcut("r")
                .help(controller.isRefreshing ? "Refreshing profiles…" : "Refresh all profiles")
                .accessibilityLabel("Refresh all profiles")
            }

            Text(controller.isRefreshing ? "Refreshing…" : headerMetaText(filterBar: listPresentation.filterBar))
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
                    switchAndOpen: snapshot.profile.codexAccountKey == nil || !controller.switchingProfileIDs.isEmpty ? nil : {
                        Task<Void, Never> { @MainActor in await controller.switchAndOpen(profileID: snapshot.id) }
                    },
                    switchOpenChamber: snapshot.profile.openCodeOpenAIAccount == nil || !controller.openCodeSwitchingProfileIDs.isEmpty ? nil : {
                        Task<Void, Never> { @MainActor in await controller.switchOpenChamberAuth(profileID: snapshot.id) }
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
                    if snapshot.profile.provider == .codex {
                        Button("Switch OpenChamber OpenAI") {
                            Task { await controller.switchOpenChamberAuth(profileID: snapshot.id) }
                        }
                        .disabled(snapshot.profile.openCodeOpenAIAccount == nil || !controller.openCodeSwitchingProfileIDs.isEmpty)
                        Divider()
                    }
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
            Button {
                performFooterAction(.openManager)
            } label: {
                Label("Manage profiles", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(CodexSecondaryButtonStyle())

            Spacer(minLength: 0)

            Button {
                performFooterAction(.openThemeSettings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(CodexQuietButtonStyle(horizontalPadding: 0, verticalPadding: 0))
            .help("Settings")
            .accessibilityLabel("Settings")

            Menu {
                Button("Email tools…", systemImage: "envelope") { performFooterAction(.openEmailTools) }
                Divider()
                Button("Larger text", systemImage: "textformat.size.larger", action: zoomPanelIn)
                    .disabled(panelTextScale >= MenuBarPanelTextScalePreference.maximumScale)
                Button("Smaller text", systemImage: "textformat.size.smaller", action: zoomPanelOut)
                    .disabled(panelTextScale <= MenuBarPanelTextScalePreference.minimumScale)
                Divider()
                Button("Quit CodexPlusBar", action: quitApp)
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options")
            .help("More options")
        }
        .padding(.top, 4)
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
            query: query,
            displayOrder: profileDisplayOrder
        ).displayedProfiles
    }

    private var profileListPresentation: ProfileListPresentation {
        ProfileListPresentation(
            profiles: controller.profiles,
            filter: profileFilter,
            query: profileSearchQuery,
            displayOrder: profileDisplayOrder
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

    private func toggleLimitFilter(_ limit: ProfileLimitFilter) {
        profileFilter.toggle(limit)
    }

    private func toggleProfileTagFilter(_ tag: PlusProfileTag) {
        profileFilter.toggle(tag)
    }

    private func toggleProfileProviderFilter(_ provider: ProfileProvider) {
        profileFilter.toggle(provider)
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

private struct MenuBarSearchButton: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
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
        .foregroundStyle(isActive ? CodexTheme.searchActionToken(preset: themeContext.preset).color : CodexTheme.palette(for: themeContext.preset).primaryText.color)
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

private struct MenuBarProfileRow: View {
    let snapshot: PlusProfileSnapshot
    let referenceDate: Date
    let isPinned: Bool
    let textScale: Double
    let searchPhoneNumber: String?
    let openManagerWindow: () -> Void
    let switchAndOpen: (() -> Void)?
    let switchOpenChamber: (() -> Void)?
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
            pinAction: pinProfile,
            switchAction: switchAndOpen,
            openChamberSwitchAction: switchOpenChamber
        )
    }
}

enum MenuBarPanelMetrics {
    static let width: CGFloat = 440
    static let height: CGFloat = 560
    static let chromeInset: CGFloat = 0
    static let innerPadding: CGFloat = 16
    static let stackSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let contentWidth = width - (chromeInset * 2) - (innerPadding * 2)
}
