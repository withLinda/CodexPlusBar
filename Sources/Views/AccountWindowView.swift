import AppKit
import SwiftUI

struct ProfileManagerLabelCopyButtonPresentation: Equatable, Sendable {
    let title: String
    let symbolName: String
    let helpText: String
    let accessibilityLabel: String
    let copyText: String
    let isCopied: Bool

    init(labelDraft: String, isCopied: Bool) {
        let copyText = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        self.copyText = copyText
        self.isCopied = isCopied
        title = isCopied ? "Copied" : "Copy"
        symbolName = isCopied ? "checkmark" : "doc.on.doc"
        helpText = copyText.isEmpty ? "Add a profile label before copying it." : "Copy profile label"
        accessibilityLabel = isCopied ? "Profile label copied" : "Copy profile label"
    }

    var isDisabled: Bool {
        copyText.isEmpty
    }
}

struct ProfileManagerEmailLinkButtonPresentation: Equatable, Sendable {
    let title = "Open"
    let symbolName = "arrow.up.forward.square"
    let helpText: String
    let accessibilityLabel = "Open email link"
    let isDisabled: Bool

    init(profile: PlusProfile) {
        isDisabled = profile.resolvedEmailLinkURL == nil
        helpText = isDisabled
            ? "Add an email link before opening it."
            : "Open email link"
    }
}

struct ProfileManagerPrivateFieldPresentation: Equatable, Sendable {
    let title: String
    let copyText: String
    let isRevealed: Bool
    let isCopied: Bool

    init(title: String, value: String, isRevealed: Bool, isCopied: Bool) {
        self.title = title
        copyText = value
        self.isRevealed = isRevealed
        self.isCopied = isCopied
    }

    var isCopyDisabled: Bool {
        copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var copyTitle: String {
        isCopied ? "Copied" : "Copy"
    }

    var copySymbolName: String {
        isCopied ? "checkmark" : "doc.on.doc"
    }

    var revealTitle: String {
        isRevealed ? "Hide" : "Show"
    }

    var revealSymbolName: String {
        isRevealed ? "eye.slash" : "eye"
    }
}

struct ProfileManagerDetailsFormPresentation: Equatable, Sendable {
    let draft: PlusProfileDetailsDraft
    let savedDraft: PlusProfileDetailsDraft
    let isSaved: Bool

    init(draft: PlusProfileDetailsDraft, profile: PlusProfile, isSaved: Bool) {
        self.draft = draft
        savedDraft = PlusProfileDetailsDraft(profile: profile)
        self.isSaved = isSaved
    }

    var isSaveEnabled: Bool {
        draft != savedDraft
    }

    var saveTitle: String {
        isSaved ? "Saved" : "Save changes"
    }

    var saveSymbolName: String {
        isSaved ? "checkmark" : "square.and.arrow.down"
    }
}

enum ProfilePrivateField: Hashable {
    case password
    case twoFactorCode
}

enum ProfileDetailsCopyField: Hashable {
    case label
    case password
    case twoFactorCode
    case phoneNumber
}

struct ProfileManagerDetailLayoutMetrics: Equatable {
    let detailStackSpacing: CGFloat
    let topGridSpacing: CGFloat
    let compactCardPadding: CGFloat
    let actionPanelWidth: CGFloat
    let actionGridColumnCount: Int
    let actionButtonSize: CGFloat
    let actionButtonSpacing: CGFloat
    let usageMetricSpacing: CGFloat
    let usageMetricTextScale: Double

    static let chromeSignIn = ProfileManagerDetailLayoutMetrics(
        detailStackSpacing: 12,
        topGridSpacing: 12,
        compactCardPadding: 12,
        actionPanelWidth: 168,
        actionGridColumnCount: 3,
        actionButtonSize: 36,
        actionButtonSpacing: 8,
        usageMetricSpacing: 10,
        usageMetricTextScale: 0.9
    )

    var actionGridColumns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(actionButtonSize),
                spacing: actionButtonSpacing,
                alignment: .leading
            ),
            count: actionGridColumnCount
        )
    }
}

struct ProfileManagerSessionPanelPresentation: Equatable, Sendable {
    let title = "Chrome sign-in"
    let summaryText: String
    let primaryTitle = "Open Chrome"
    let passkeyHelpTitle = "Touch ID help"
    let syncTitle = "Sync now"
    let cancelTitle = "Cancel"
    let isSyncDisabled: Bool
    let showsCancel: Bool

    init(snapshot: PlusProfileSnapshot, isChromeSignInOpen: Bool) {
        isSyncDisabled = isChromeSignInOpen == false || snapshot.isRefreshing
        showsCancel = isChromeSignInOpen

        if isChromeSignInOpen {
            summaryText = snapshot.statusMessage ?? "Waiting for sign-in in Chrome."
            return
        }

        if let statusMessage = snapshot.statusMessage, snapshot.state == .failed {
            summaryText = statusMessage
            return
        }

        switch snapshot.state {
        case .idle, .needsLogin:
            summaryText = "Open Chrome, sign in, then sync."
        case .loading:
            summaryText = "Checking this profile."
        case .ready:
            summaryText = "Session is synced."
        case .failed:
            summaryText = "Open Chrome to repair this profile."
        }
    }
}

struct ProfileManagerWindowView: View {
    @Bindable var controller: PlusProfileController
    let currentTime: AppMinuteClock
    @Environment(\.displayScale) private var displayScale
    @State private var windowChromeMetrics = WindowChromeMetrics()
    @State private var detailsDraft = PlusProfileDetailsDraft()
    @State private var sidebarTagFilter = ProfileTagFilter()
    @State private var revealedPrivateFields: Set<ProfilePrivateField> = []
    @State private var copiedField: ProfileDetailsCopyField?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var showsSavedConfirmation = false
    @State private var saveResetTask: Task<Void, Never>?

    init(
        controller: PlusProfileController,
        currentTime: AppMinuteClock
    ) {
        self.controller = controller
        self.currentTime = currentTime
    }

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

                    if let message = controller.statusMessage {
                        ProfileManagerStatusBanner(
                            title: controller.dashboardStatus.title,
                            message: message,
                            tone: controller.dashboardStatus.tone,
                            symbolName: controller.dashboardStatus.symbolName
                        )
                    }

                    bodyContent
                }
                .padding(.top, CodexTheme.chromePadding)
                .padding(.horizontal, CodexTheme.chromePadding)
                .padding(.bottom, CodexTheme.chromePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1080, minHeight: 760)
        .background(Color.clear)
        .overlay(alignment: .topLeading) {
            WindowChromeMetricsReader(metrics: $windowChromeMetrics)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .codexThemeRefreshScope()
        .onAppear {
            syncDrafts(with: controller.selectedProfile)
        }
        .onChange(of: controller.selectedProfileID) { _, _ in
            resetDetailsFeedback()
            syncDrafts(with: controller.selectedProfile)
        }
        .onChange(of: detailsDraft) { _, newDraft in
            guard let snapshot = controller.selectedProfile else {
                return
            }

            if newDraft != PlusProfileDetailsDraft(profile: snapshot.profile) {
                resetSaveFeedback()
            }
        }
        .onDisappear {
            resetDetailsFeedback()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CodexPlusBar")
                    .font(ProfileManagerTypography.micro)
                    .foregroundStyle(CodexTheme.utilityActionText)
                    .kerning(1.4)

                Text("Profile Manager")
                    .font(ProfileManagerTypography.title)
                    .foregroundStyle(CodexTheme.headingText)

                Text(headerMetaText)
                    .font(ProfileManagerTypography.body)
                    .foregroundStyle(CodexTheme.mutedText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 10) {
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

                HStack(spacing: 10) {
                    Button(action: refreshAll) {
                        Label("Refresh all", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ProfileManagerPrimaryButtonStyle())
                    .disabled(controller.isRefreshing || controller.profiles.isEmpty)

                    Button(action: addProfile) {
                        Label("Add profile", systemImage: "plus")
                    }
                    .buttonStyle(ProfileManagerSecondaryButtonStyle())
                }
            }
        }
    }

    private var bodyContent: some View {
        HStack(alignment: .top, spacing: CodexTheme.contentSpacing) {
            sidebar
                .frame(width: 280, alignment: .topLeading)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        CodexCard(tier: .regular) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Saved profiles")
                            .font(ProfileManagerTypography.bodyStrong)
                            .foregroundStyle(CodexTheme.headingText)

                        Text(sidebarMetaText)
                            .font(ProfileManagerTypography.caption)
                            .foregroundStyle(CodexTheme.mutedText)
                    }

                    Spacer(minLength: 0)

                    Button(action: addProfile) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(CodexSecondaryButtonStyle())
                }

                if controller.profiles.isEmpty {
                    Text("Add a profile, then sign in with one email account at a time.")
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProfileTagFilterBar(
                        presentation: sidebarFilterPresentation,
                        clearFilter: clearSidebarFilter,
                        toggleTag: toggleSidebarFilter
                    )

                    if filteredSidebarProfiles.isEmpty {
                        ProfileTagEmptyState(clearFilter: clearSidebarFilter)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredSidebarProfiles) { snapshot in
                                    Button {
                                        controller.selectProfile(id: snapshot.id)
                                    } label: {
                                        ProfileSummaryRow(
                                            snapshot: snapshot,
                                            referenceDate: currentTime.now,
                                            mode: .sidebar(
                                                isSelected: snapshot.id == controller.selectedProfileID
                                            )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let snapshot = controller.selectedProfile {
            let metrics = ProfileManagerDetailLayoutMetrics.chromeSignIn

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: metrics.detailStackSpacing) {
                    detailTopGrid(for: snapshot, metrics: metrics)
                    usagePanel(for: snapshot, metrics: metrics)
                    chromeSignInPanel(for: snapshot, metrics: metrics)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, metrics.detailStackSpacing)
            }
        } else {
            CodexCard(tier: .strong) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a profile")
                        .font(ProfileManagerTypography.bodyStrong)
                        .foregroundStyle(CodexTheme.headingText)

                    Text("Pick a profile from the left to inspect usage, repair login, or remove it.")
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func detailTopGrid(
        for snapshot: PlusProfileSnapshot,
        metrics: ProfileManagerDetailLayoutMetrics
    ) -> some View {
        HStack(alignment: .top, spacing: metrics.topGridSpacing) {
            detailHeader(for: snapshot, metrics: metrics)
                .layoutPriority(1)

            actionPanel(for: snapshot, metrics: metrics)
                .frame(width: metrics.actionPanelWidth, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func detailHeader(
        for snapshot: PlusProfileSnapshot,
        metrics: ProfileManagerDetailLayoutMetrics
    ) -> some View {
        CodexCard(
            tier: .strong,
            accent: detailAccent(for: snapshot),
            padding: metrics.compactCardPadding
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        profileDetailsForm(for: snapshot)

                        ProfileTagAssignmentSection(
                            selectedTags: snapshot.tags,
                            toggleTag: { tag in
                                toggleTag(tag, for: snapshot.id)
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)

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
                    }
                }

                if let note = snapshot.note {
                    Text(note)
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.supportText)
                }

                if shouldShowExpiry(for: snapshot) {
                    detailExpiryLine(for: snapshot)
                }

                Text(detailSummary(for: snapshot))
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profileDetailsForm(for snapshot: PlusProfileSnapshot) -> some View {
        let formPresentation = ProfileManagerDetailsFormPresentation(
            draft: detailsDraft,
            profile: snapshot.profile,
            isSaved: showsSavedConfirmation
        )

        return VStack(alignment: .leading, spacing: 12) {
            if formPresentation.isSaveEnabled || showsSavedConfirmation {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    Button {
                        saveDetailsDraft(for: snapshot)
                    } label: {
                        Label(formPresentation.saveTitle, systemImage: formPresentation.saveSymbolName)
                    }
                    .buttonStyle(ProfileManagerSecondaryButtonStyle())
                    .disabled(formPresentation.isSaveEnabled == false)
                }
            }

            ProfileManagerDetailsTextField(
                title: "Profile label",
                placeholder: "Email or label",
                text: $detailsDraft.label,
                onSubmit: {
                    saveDetailsDraftIfNeeded(for: snapshot)
                }
            ) {
                ProfileManagerLabelCopyButton(
                    presentation: labelCopyButtonPresentation(),
                    action: copyLabelDraft
                )
            }

            ProfileManagerDetailsTextField(
                title: "Email link",
                placeholder: "https://mail.google.com",
                text: $detailsDraft.emailLink,
                onSubmit: {
                    saveDetailsDraftIfNeeded(for: snapshot)
                }
            ) {
                ProfileManagerEmailLinkButton(
                    presentation: ProfileManagerEmailLinkButtonPresentation(profile: snapshot.profile),
                    action: {
                        openEmailLink(for: snapshot.profile)
                    }
                )
            }

            ProfileManagerPrivateDetailsField(
                title: "Password",
                placeholder: "Saved only in this local profile file",
                text: $detailsDraft.password,
                presentation: ProfileManagerPrivateFieldPresentation(
                    title: "Password",
                    value: detailsDraft.password,
                    isRevealed: revealedPrivateFields.contains(.password),
                    isCopied: copiedField == .password
                ),
                onSubmit: {
                    saveDetailsDraftIfNeeded(for: snapshot)
                },
                toggleReveal: {
                    togglePrivateField(.password)
                },
                copy: {
                    copy(detailsDraft.password, field: .password)
                }
            )

            ProfileManagerPrivateDetailsField(
                title: "2FA codes",
                placeholder: "Text to paste into 2fa.live",
                text: $detailsDraft.twoFactorCode,
                presentation: ProfileManagerPrivateFieldPresentation(
                    title: "2FA codes",
                    value: detailsDraft.twoFactorCode,
                    isRevealed: revealedPrivateFields.contains(.twoFactorCode),
                    isCopied: copiedField == .twoFactorCode
                ),
                onSubmit: {
                    saveDetailsDraftIfNeeded(for: snapshot)
                },
                toggleReveal: {
                    togglePrivateField(.twoFactorCode)
                },
                copy: {
                    copy(detailsDraft.twoFactorCode, field: .twoFactorCode)
                }
            )

            ProfileManagerDetailsTextField(
                title: "Phone number",
                placeholder: "+62 812 3456",
                text: $detailsDraft.phoneNumber,
                onSubmit: {
                    saveDetailsDraftIfNeeded(for: snapshot)
                }
            ) {
                ProfileManagerInlineFieldActionButton(
                    title: copiedField == .phoneNumber ? "Copied" : "Copy",
                    symbolName: copiedField == .phoneNumber ? "checkmark" : "doc.on.doc",
                    helpText: phoneNumberCopyText.isEmpty ? "Add a phone number before copying it." : "Copy phone number",
                    accessibilityLabel: copiedField == .phoneNumber ? "Phone number copied" : "Copy phone number",
                    isDisabled: phoneNumberCopyText.isEmpty,
                    isConfirmed: copiedField == .phoneNumber,
                    action: {
                        copy(phoneNumberCopyText, field: .phoneNumber)
                    }
                )
            }

            ProfileManagerNotesDetailsField(
                title: "Notes",
                placeholder: "Short note for this account",
                text: $detailsDraft.notes
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usagePanel(
        for snapshot: PlusProfileSnapshot,
        metrics: ProfileManagerDetailLayoutMetrics
    ) -> some View {
        CodexCard(tier: .regular, padding: metrics.compactCardPadding) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Usage")
                    .font(ProfileManagerTypography.bodyStrong)
                    .foregroundStyle(CodexTheme.headingText)

                if let usageSummary = snapshot.usageSummary(referenceDate: currentTime.now) {
                    HStack(spacing: metrics.usageMetricSpacing) {
                        ProfileUsageMetricBlock(
                            summary: usageSummary.primary,
                            density: .expanded,
                            textScale: metrics.usageMetricTextScale
                        )

                        ProfileUsageMetricBlock(
                            summary: usageSummary.secondary,
                            density: .expanded,
                            textScale: metrics.usageMetricTextScale
                        )
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Usage windows")
                    .accessibilityValue(usageSummary.accessibilityValue)
                } else {
                    Text(snapshot.statusMessage ?? "Live usage will appear here after a successful refresh.")
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(snapshot.state.tone.foregroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionPanel(
        for snapshot: PlusProfileSnapshot,
        metrics: ProfileManagerDetailLayoutMetrics
    ) -> some View {
        CodexCard(tier: .regular, padding: metrics.compactCardPadding) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Actions")
                    .font(ProfileManagerTypography.bodyStrong)
                    .foregroundStyle(CodexTheme.headingText)

                LazyVGrid(
                    columns: metrics.actionGridColumns,
                    alignment: .leading,
                    spacing: metrics.actionButtonSpacing
                ) {
                    CodexIconButton(
                        symbolName: "arrow.clockwise",
                        helpText: "Refresh profile",
                        tone: .primary,
                        isDisabled: snapshot.isRefreshing
                    ) {
                        refreshProfile(snapshot.id)
                    }

                    CodexIconButton(
                        symbolName: "globe",
                        helpText: "Open Chrome sign-in",
                        tone: .secondary
                    ) {
                        openChromeSignIn(snapshot.id)
                    }

                    CodexIconButton(
                        symbolName: "xmark.circle",
                        helpText: "Clear session",
                        tone: .danger
                    ) {
                        clearSession(snapshot.id)
                    }

                    CodexIconButton(
                        symbolName: "arrow.up",
                        helpText: "Move profile up",
                        tone: .secondary,
                        isDisabled: isMoveUpDisabled(for: snapshot)
                    ) {
                        controller.selectProfile(id: snapshot.id)
                        controller.moveSelectedProfileUp()
                    }

                    CodexIconButton(
                        symbolName: "arrow.down",
                        helpText: "Move profile down",
                        tone: .secondary,
                        isDisabled: isMoveDownDisabled(for: snapshot)
                    ) {
                        controller.selectProfile(id: snapshot.id)
                        controller.moveSelectedProfileDown()
                    }

                    CodexIconButton(
                        symbolName: "trash",
                        helpText: "Remove profile",
                        tone: .danger
                    ) {
                        removeProfile(snapshot.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func chromeSignInPanel(
        for snapshot: PlusProfileSnapshot,
        metrics: ProfileManagerDetailLayoutMetrics
    ) -> some View {
        let presentation = ProfileManagerSessionPanelPresentation(
            snapshot: snapshot,
            isChromeSignInOpen: controller.isChromeSignInOpen(for: snapshot.id)
        )

        CodexCard(tier: .strong, padding: metrics.compactCardPadding) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CodexTheme.accentOrange)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(ProfileManagerTypography.bodyStrong)
                        .foregroundStyle(CodexTheme.headingText)

                    Text(presentation.summaryText)
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        openChromeSignIn(snapshot.id)
                    } label: {
                        Label(presentation.primaryTitle, systemImage: "globe")
                    }
                    .buttonStyle(ProfileManagerPrimaryButtonStyle())
                    .disabled(snapshot.isRefreshing)

                    CodexIconButton(
                        symbolName: "touchid",
                        helpText: presentation.passkeyHelpTitle,
                        tone: .quiet,
                        isDisabled: snapshot.isRefreshing
                    ) {
                        openChromePasskeySetup(snapshot.id)
                    }

                    Button(presentation.syncTitle) {
                        syncChromeSession(snapshot.id)
                    }
                    .buttonStyle(ProfileManagerSecondaryButtonStyle())
                    .disabled(presentation.isSyncDisabled)

                    if presentation.showsCancel {
                        Button(presentation.cancelTitle) {
                            closeChromeSignIn(snapshot.id)
                        }
                        .buttonStyle(ProfileManagerSecondaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerMetaText: String {
        let count = controller.profiles.count
        let countLabel = count == 1 ? "1 saved profile" : "\(count) saved profiles"

        if let refreshedAt = controller.profiles.compactMap(\.lastRefreshAt).max(),
           let updatedText = DisplayFormatter.updatedText(refreshedAt, referenceDate: currentTime.now) {
            return "\(updatedText) · \(countLabel)"
        }

        return count == 0 ? "Add your first profile to begin" : countLabel
    }

    var filteredSidebarProfiles: [PlusProfileSnapshot] {
        PlusProfileSnapshot.expiryFirstDisplayOrder(
            sidebarTagFilter.apply(to: controller.profiles)
        )
    }

    private var profileTagCounts: ProfileTagCounts {
        ProfileTagCounts(snapshots: controller.profiles)
    }

    private var sidebarFilterPresentation: ProfileTagFilterBarPresentation {
        ProfileTagFilterBarPresentation(
            filter: sidebarTagFilter,
            shownCount: filteredSidebarProfiles.count,
            totalCount: controller.profiles.count,
            tagCounts: profileTagCounts
        )
    }

    private var sidebarMetaText: String {
        if controller.profiles.isEmpty {
            return "No saved profiles yet"
        }

        return sidebarFilterPresentation.visibleSummaryText
    }

    private func detailSummary(for snapshot: PlusProfileSnapshot) -> String {
        if let updatedText = DisplayFormatter.updatedText(snapshot.lastRefreshAt, referenceDate: currentTime.now) {
            return updatedText
        }

        switch snapshot.state {
        case .idle:
            return "Ready for first login or first refresh."
        case .loading:
            return "Loading live usage for this profile."
        case .ready:
            return "Live usage is loaded."
        case .needsLogin:
            return "This profile needs a fresh ChatGPT login."
        case .failed:
            return snapshot.statusMessage ?? "The last refresh failed."
        }
    }

    private func detailAccent(for snapshot: PlusProfileSnapshot) -> Color? {
        if let remaining = snapshot.usage?.fiveHourRemainingPercent {
            return CodexTheme.usagePercentageColor(forRemainingPercent: remaining)
        }

        return snapshot.state == .ready ? nil : snapshot.state.tone.foregroundColor
    }

    private func isMoveUpDisabled(for snapshot: PlusProfileSnapshot) -> Bool {
        controller.profiles.first?.id == snapshot.id
    }

    private func isMoveDownDisabled(for snapshot: PlusProfileSnapshot) -> Bool {
        controller.profiles.last?.id == snapshot.id
    }

    private func shouldShowExpiry(for snapshot: PlusProfileSnapshot) -> Bool {
        snapshot.expiresAt != nil || snapshot.usage != nil || snapshot.lastRefreshAt != nil
    }

    @ViewBuilder
    private func detailExpiryLine(for snapshot: PlusProfileSnapshot) -> some View {
        let presentation = DisplayFormatter.expiryValue(
            snapshot.expiresAt,
            referenceDate: currentTime.now
        )
        let emphasisToken = CodexTheme.expiryEmphasisToken(
            for: snapshot.expiresAt,
            referenceDate: currentTime.now
        )

        Group {
            if let label = presentation.label {
                (
                    Text(label + " ")
                        .foregroundStyle(CodexTheme.dataLabelText)
                    + Text(presentation.value)
                        .foregroundStyle(emphasisToken?.color ?? CodexTheme.dataValueText)
                        .monospacedDigit()
                )
                .font(ProfileManagerTypography.small)
            } else {
                Text(presentation.value)
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(emphasisToken?.color ?? CodexTheme.dataValueText)
            }
        }
        .lineLimit(1)
    }

    private func syncDrafts(with snapshot: PlusProfileSnapshot?) {
        detailsDraft = snapshot.map { PlusProfileDetailsDraft(profile: $0.profile) } ?? .init()
    }

    private func isDetailsSaveEnabled(for snapshot: PlusProfileSnapshot) -> Bool {
        ProfileManagerDetailsFormPresentation(
            draft: detailsDraft,
            profile: snapshot.profile,
            isSaved: showsSavedConfirmation
        ).isSaveEnabled
    }

    private func saveDetailsDraftIfNeeded(for snapshot: PlusProfileSnapshot) {
        guard isDetailsSaveEnabled(for: snapshot) else {
            return
        }

        saveDetailsDraft(for: snapshot)
    }

    private func saveDetailsDraft(for snapshot: PlusProfileSnapshot) {
        let didSave = controller.updateDetails(for: snapshot.id, draft: detailsDraft)
        guard didSave else {
            return
        }

        detailsDraft = controller.profiles
            .first(where: { $0.id == snapshot.id })
            .map { PlusProfileDetailsDraft(profile: $0.profile) } ?? detailsDraft
        showsSavedConfirmation = true
        scheduleSaveReset()
    }

    private func labelCopyButtonPresentation() -> ProfileManagerLabelCopyButtonPresentation {
        ProfileManagerLabelCopyButtonPresentation(
            labelDraft: detailsDraft.label,
            isCopied: copiedField == .label
        )
    }

    private var phoneNumberCopyText: String {
        detailsDraft.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyLabelDraft() {
        let presentation = labelCopyButtonPresentation()
        guard presentation.isDisabled == false else {
            return
        }

        copy(presentation.copyText, field: .label)
    }

    private func copy(_ text: String, field: ProfileDetailsCopyField) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        copiedField = field
        scheduleCopyReset(for: field)
    }

    private func scheduleCopyReset(for field: ProfileDetailsCopyField) {
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [field] in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard Task.isCancelled == false, copiedField == field else {
                return
            }

            copiedField = nil
            copyResetTask = nil
        }
    }

    private func scheduleSaveReset() {
        saveResetTask?.cancel()
        saveResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard Task.isCancelled == false else {
                return
            }

            showsSavedConfirmation = false
            saveResetTask = nil
        }
    }

    private func togglePrivateField(_ field: ProfilePrivateField) {
        if revealedPrivateFields.contains(field) {
            revealedPrivateFields.remove(field)
        } else {
            revealedPrivateFields.insert(field)
        }
    }

    private func resetSaveFeedback() {
        saveResetTask?.cancel()
        saveResetTask = nil
        showsSavedConfirmation = false
    }

    private func resetDetailsFeedback() {
        copyResetTask?.cancel()
        copyResetTask = nil
        copiedField = nil
        revealedPrivateFields.removeAll()
        resetSaveFeedback()
    }

    private func openEmailLink(for profile: PlusProfile) {
        guard let url = profile.resolvedEmailLinkURL else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func refreshAll() {
        Task {
            await controller.refreshAll()
        }
    }

    private func refreshProfile(_ profileID: UUID) {
        Task {
            await controller.refreshProfile(id: profileID)
        }
    }

    private func addProfile() {
        controller.addProfile()
    }

    private func clearSidebarFilter() {
        sidebarTagFilter.clear()
    }

    private func toggleSidebarFilter(_ tag: PlusProfileTag) {
        sidebarTagFilter.toggle(tag)

        guard let selectedProfileID = controller.selectedProfileID,
              filteredSidebarProfiles.isEmpty == false,
              filteredSidebarProfiles.contains(where: { $0.id == selectedProfileID }) == false else {
            return
        }

        controller.selectProfile(id: filteredSidebarProfiles.first?.id)
    }

    private func toggleTag(_ tag: PlusProfileTag, for profileID: UUID) {
        controller.toggleTag(tag, for: profileID)
    }

    private func clearSession(_ profileID: UUID) {
        Task {
            await controller.clearSession(for: profileID)
        }
    }

    private func removeProfile(_ profileID: UUID) {
        Task {
            await controller.removeProfile(id: profileID)
        }
    }

    private func openChromeSignIn(_ profileID: UUID) {
        Task {
            await controller.openChromeSignIn(for: profileID)
        }
    }

    private func openChromePasskeySetup(_ profileID: UUID) {
        Task {
            await controller.openChromePasskeySetup(for: profileID)
        }
    }

    private func syncChromeSession(_ profileID: UUID) {
        Task {
            await controller.syncChromeSession(for: profileID)
        }
    }

    private func closeChromeSignIn(_ profileID: UUID) {
        Task {
            await controller.closeChromeSignIn(for: profileID)
        }
    }
}

private struct ProfileTagAssignmentSection: View {
    let selectedTags: [PlusProfileTag]
    let toggleTag: (PlusProfileTag) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.supportText)

            HStack(spacing: 6) {
                ForEach(PlusProfileTag.allCases) { tag in
                    ProfileTagToggleChip(
                        title: tag.displayName,
                        systemImage: tag.systemImage,
                        isSelected: selectedTags.contains(tag),
                        tone: tag.statusTone,
                        helpText: selectedTags.contains(tag)
                            ? "Remove \(tag.displayName) tag"
                            : "Mark as \(tag.displayName)"
                    ) {
                        toggleTag(tag)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Profile tags")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfileManagerDetailsTextField<TrailingContent: View>: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    let trailingContent: TrailingContent

    init(
        title: String,
        placeholder: String,
        text: Binding<String>,
        onSubmit: @escaping () -> Void,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        self.title = title
        self.placeholder = placeholder
        _text = text
        self.onSubmit = onSubmit
        self.trailingContent = trailingContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.dataLabelText)

            HStack(alignment: .center, spacing: 10) {
                TextField(placeholder, text: $text)
                    .font(ProfileManagerTypography.body)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(ProfileManagerFieldBackground())
                    .foregroundStyle(CodexTheme.dataValueText)
                    .submitLabel(.done)
                    .onSubmit(onSubmit)

                trailingContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfileManagerPrivateDetailsField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let presentation: ProfileManagerPrivateFieldPresentation
    let onSubmit: () -> Void
    let toggleReveal: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.dataLabelText)

            HStack(alignment: .center, spacing: 10) {
                Group {
                    if presentation.isRevealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .font(ProfileManagerTypography.body)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(ProfileManagerFieldBackground())
                .foregroundStyle(CodexTheme.dataValueText)
                .submitLabel(.done)
                .onSubmit(onSubmit)

                ProfileManagerInlineFieldActionButton(
                    title: presentation.revealTitle,
                    symbolName: presentation.revealSymbolName,
                    helpText: "\(presentation.revealTitle) \(presentation.title.lowercased())",
                    accessibilityLabel: "\(presentation.revealTitle) \(presentation.title)",
                    isDisabled: false,
                    isConfirmed: presentation.isRevealed,
                    action: toggleReveal
                )

                ProfileManagerInlineFieldActionButton(
                    title: presentation.copyTitle,
                    symbolName: presentation.copySymbolName,
                    helpText: presentation.isCopyDisabled ? "Add \(presentation.title.lowercased()) before copying it." : "Copy \(presentation.title.lowercased())",
                    accessibilityLabel: presentation.isCopied ? "\(presentation.title) copied" : "Copy \(presentation.title)",
                    isDisabled: presentation.isCopyDisabled,
                    isConfirmed: presentation.isCopied,
                    action: copy
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfileManagerNotesDetailsField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.dataLabelText)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(ProfileManagerTypography.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(minHeight: 72, maxHeight: 108)
                    .background(ProfileManagerFieldBackground())
                    .foregroundStyle(CodexTheme.dataValueText)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(ProfileManagerTypography.body)
                        .foregroundStyle(CodexTheme.quietText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfileManagerFieldBackground: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: CodexTheme.fieldCornerRadius,
            style: .continuous
        )
        .fill(CodexTheme.surfaceFill(for: .nested))
        .overlay {
            RoundedRectangle(
                cornerRadius: CodexTheme.fieldCornerRadius,
                style: .continuous
            )
            .stroke(CodexTheme.surfaceBorder(for: .nested), lineWidth: 1)
        }
    }
}

private struct ProfileManagerLabelCopyButton: View {
    let presentation: ProfileManagerLabelCopyButtonPresentation
    let action: () -> Void

    var body: some View {
        ProfileManagerInlineFieldActionButton(
            title: presentation.title,
            symbolName: presentation.symbolName,
            helpText: presentation.helpText,
            accessibilityLabel: presentation.accessibilityLabel,
            isDisabled: presentation.isDisabled,
            isConfirmed: presentation.isCopied,
            action: action
        )
    }
}

private struct ProfileManagerEmailLinkButton: View {
    let presentation: ProfileManagerEmailLinkButtonPresentation
    let action: () -> Void

    var body: some View {
        ProfileManagerInlineFieldActionButton(
            title: presentation.title,
            symbolName: presentation.symbolName,
            helpText: presentation.helpText,
            accessibilityLabel: presentation.accessibilityLabel,
            isDisabled: presentation.isDisabled,
            isConfirmed: false,
            action: action
        )
    }
}

private struct ProfileManagerInlineFieldActionButton: View {
    let title: String
    let symbolName: String
    let helpText: String
    let accessibilityLabel: String
    let isDisabled: Bool
    let isConfirmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)

                Text(title)
            }
        }
        .buttonStyle(ProfileManagerInlineFieldActionButtonStyle(isConfirmed: isConfirmed))
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(helpText)
        .help(helpText)
    }
}

private struct ProfileManagerInlineFieldActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let isConfirmed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.caption)
            .foregroundStyle(foregroundColor)
            .frame(width: 94, height: 38)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .fill(CodexTheme.surfaceSheen(for: .subtle))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.16), value: isConfirmed)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return CodexTheme.disabledText
        }

        return isConfirmed ? CodexTheme.successText : CodexTheme.utilityActionText
    }

    private var borderColor: Color {
        guard isEnabled else {
            return CodexTheme.surfaceBorder(for: .subtle)
        }

        return isConfirmed
            ? CodexTheme.accentAqua.opacity(0.34)
            : CodexTheme.surfaceBorder(for: .subtle)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isConfirmed {
            return CodexTheme.accentAqua.opacity(isPressed ? 0.16 : 0.12)
        }

        return CodexTheme.surfaceFill(for: .subtle).opacity(isPressed ? 0.98 : 0.92)
    }
}

private struct ProfileManagerStatusBanner: View {
    let title: String
    let message: String
    let tone: CodexStatusTone
    let symbolName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                            .stroke(tone.borderColor, lineWidth: 1)
                    )

                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone.foregroundColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: CodexTheme.Spacing.micro) {
                Text(title)
                    .font(ProfileManagerTypography.smallStrong)
                    .foregroundStyle(CodexTheme.headingText)

                Text(message)
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(CodexTheme.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .nested))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                        .fill(tone.backgroundColor.opacity(0.52))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                        .stroke(tone.borderColor, lineWidth: 1)
                )
        )
    }
}

private struct ProfileManagerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(isEnabled ? CodexTheme.accentInk : CodexTheme.disabledText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        isEnabled
                            ? AnyShapeStyle(CodexTheme.accentGradient)
                            : AnyShapeStyle(CodexTheme.surfaceFill(for: .subtle))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .stroke(
                                isEnabled
                                    ? Color.white.opacity(0.08)
                                    : CodexTheme.surfaceBorder(for: .subtle),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: isEnabled ? CodexTheme.accentOrange.opacity(0.20) : .clear, radius: 12, y: 6)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct ProfileManagerSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(isEnabled ? CodexTheme.actionText : CodexTheme.disabledText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
            .shadow(color: isEnabled ? .black.opacity(0.16) : .clear, radius: 8, y: 4)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct ProfileManagerDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(isEnabled ? CodexTheme.dangerText : CodexTheme.disabledText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        isEnabled
                            ? CodexTheme.accentRed.opacity(configuration.isPressed ? 0.16 : 0.10)
                            : CodexTheme.surfaceFill(for: .subtle)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(
                        isEnabled
                            ? CodexTheme.accentRed.opacity(0.24)
                            : CodexTheme.surfaceBorder(for: .subtle),
                        lineWidth: 1
                    )
            )
    }
}

struct AccountWindowTitleBarGlass: View {
    let height: CGFloat
    let seamOverlap: CGFloat

    private var warmTintGradient: LinearGradient {
        let palette = CodexTheme.activePalette

        return LinearGradient(
            colors: [
                palette.bg1.color(alpha: palette.isDark ? 0.02 : 0.10),
                palette.bgDim.color(alpha: palette.isDark ? 0.07 : 0.18),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var shape: some Shape {
        AccountWindowTitleBarGlassShape(cornerRadius: CodexTheme.shellCornerRadius)
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                Group {
                    if #available(macOS 26.0, *) {
                        Rectangle()
                            .fill(.clear)
                            .glassEffect(
                                Glass.clear.tint(CodexTheme.activePalette.bg1.color(alpha: CodexTheme.isDarkTheme ? 0.035 : 0.10)),
                                in: shape
                            )
                            .overlay {
                                warmTintGradient
                            }
                    } else {
                        WindowTitleBarVisualEffectView()
                            .overlay {
                                warmTintGradient
                            }
                    }
                }
                .clipShape(shape)
                .frame(maxWidth: .infinity)
                .frame(height: height + seamOverlap)
            }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

struct AccountWindowTitleBarGlassShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        if #available(macOS 14.0, *) {
            return UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
            .path(in: rect)
        } else {
            return legacyPath(in: rect)
        }
    }

    private func legacyPath(in rect: CGRect) -> Path {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: minX + radius, y: minY),
            control: CGPoint(x: minX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addQuadCurve(
            to: CGPoint(x: maxX, y: minY + radius),
            control: CGPoint(x: maxX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX, y: maxY))
        path.closeSubpath()
        return path
    }
}

struct AccountWindowBodyShell<Content: View>: View {
    let seamOverlap: CGFloat
    let content: Content

    init(
        seamOverlap: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.seamOverlap = seamOverlap
        self.content = content()
    }

    var body: some View {
        let shadow = CodexTheme.shadow(for: .strong)
        let shellShape = AccountWindowBodyMask(cornerRadius: CodexTheme.shellCornerRadius)
        let borderShape = AccountWindowBodyBorderShape(cornerRadius: CodexTheme.shellCornerRadius)

        GeometryReader { proxy in
            let bodyHeight = proxy.size.height + seamOverlap

            ZStack(alignment: .topLeading) {
                shellShape
                    .fill(Color.black.opacity(0.018))
                    .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 12)
                            Rectangle()
                                .fill(Color.white)
                        }
                    }

                CodexBackdrop()
                    .mask(shellShape)

                Rectangle()
                    .fill(CodexTheme.shellFill(for: .dialog))
                    .mask(shellShape)
                    .overlay {
                        Rectangle()
                            .fill(CodexTheme.surfaceSheen(for: .strong))
                            .mask(shellShape)
                    }
                    .overlay {
                        borderShape
                            .stroke(CodexTheme.surfaceBorder(for: .strong), lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        content
                            .frame(
                                width: proxy.size.width,
                                height: bodyHeight,
                                alignment: .topLeading
                            )
                    }
            }
            .frame(width: proxy.size.width, height: bodyHeight, alignment: .topLeading)
            .offset(y: -seamOverlap)
            .clipped()
        }
    }
}

struct AccountWindowBodyMask: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        if #available(macOS 14.0, *) {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .path(in: rect)
        } else {
            return legacyPath(in: rect)
        }
    }

    private func legacyPath(in rect: CGRect) -> Path {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: maxX - radius, y: maxY),
            control: CGPoint(x: maxX, y: maxY)
        )
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: minX, y: maxY - radius),
            control: CGPoint(x: minX, y: maxY)
        )
        path.closeSubpath()
        return path
    }
}

struct AccountWindowBodyBorderShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        legacyPath(in: rect)
    }

    private func legacyPath(in rect: CGRect) -> Path {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        let minX = rect.minX + 0.5
        let maxX = rect.maxX - 0.5
        let minY = rect.minY + 0.5
        let maxY = rect.maxY - 0.5

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: minX, y: maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: minX + radius, y: maxY),
            control: CGPoint(x: minX, y: maxY)
        )
        path.addLine(to: CGPoint(x: maxX - radius, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: maxX, y: maxY - radius),
            control: CGPoint(x: maxX, y: maxY)
        )
        path.addLine(to: CGPoint(x: maxX, y: minY))
        return path
    }
}
