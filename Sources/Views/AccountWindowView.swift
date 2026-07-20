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

struct ProfileManagerOneTimePasswordClipboardValue: Equatable, Sendable {
    let text: String

    init(secret: String, referenceDate: Date = .now) throws {
        let generator = try TOTPGenerator(secret: secret)
        text = generator.code(at: referenceDate)
    }
}

struct ProfileManagerOneTimePasswordPresentation: Equatable, Sendable {
    let isVisible: Bool
    let isRevealed: Bool
    let isCopied: Bool
    let titleText: String
    let codeText: String
    let isCodeMasked: Bool
    let statusText: String
    let copyTitle: String
    let copySymbolName: String
    let isCopyDisabled: Bool
    let accessibilityValue: String
    let tone: CodexStatusTone
    let symbolName: String

    var revealTitle: String {
        isRevealed ? "Hide OTP" : "Show OTP"
    }

    var revealSymbolName: String {
        isRevealed ? "eye.slash" : "eye"
    }

    init(
        secret: String,
        isRevealed: Bool = false,
        isCopied: Bool,
        hasCopyError: Bool = false,
        referenceDate: Date
    ) {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSecret.isEmpty == false else {
            isVisible = false
            self.isRevealed = false
            self.isCopied = false
            titleText = ""
            codeText = ""
            isCodeMasked = false
            statusText = ""
            copyTitle = "Copy OTP"
            copySymbolName = "doc.on.doc"
            isCopyDisabled = true
            accessibilityValue = ""
            tone = .neutral
            symbolName = "eye.slash"
            return
        }

        guard isRevealed else {
            isVisible = true
            self.isRevealed = false
            self.isCopied = isCopied && hasCopyError == false
            titleText = "Current OTP"
            codeText = ""
            isCodeMasked = true
            copyTitle = self.isCopied ? "Copied" : "Copy OTP"
            copySymbolName = self.isCopied ? "checkmark" : "doc.on.doc"

            if hasCopyError {
                statusText = "Check 2FA key"
                isCopyDisabled = true
                accessibilityValue = "OTP covered. 2FA key is not valid."
                tone = .warning
                symbolName = "key.slash"
            } else {
                statusText = "2FA key saved"
                isCopyDisabled = false
                accessibilityValue = "OTP covered. 2FA key saved."
                tone = .info
                symbolName = "eye.slash"
            }
            return
        }

        do {
            let generator = try TOTPGenerator(secret: trimmedSecret)
            let generatedCode = generator.code(at: referenceDate)
            let secondsRemaining = generator.secondsRemaining(at: referenceDate)
            isVisible = true
            self.isRevealed = true
            self.isCopied = isCopied
            titleText = "Current OTP"
            codeText = generatedCode
            isCodeMasked = false
            statusText = "Expires in \(secondsRemaining)s"
            copyTitle = isCopied ? "Copied" : "Copy OTP"
            copySymbolName = isCopied ? "checkmark" : "doc.on.doc"
            isCopyDisabled = false
            accessibilityValue = "Current OTP \(generatedCode), expires in \(secondsRemaining) \(secondsRemaining == 1 ? "second" : "seconds")."
            tone = .info
            symbolName = "number"
        } catch {
            isVisible = true
            self.isRevealed = true
            self.isCopied = false
            titleText = "Current OTP"
            codeText = "------"
            isCodeMasked = false
            statusText = "Check 2FA key"
            copyTitle = "Copy OTP"
            copySymbolName = "doc.on.doc"
            isCopyDisabled = true
            accessibilityValue = "2FA key is not valid."
            tone = .warning
            symbolName = "key.slash"
        }
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

struct ProfileManagerBulkImportSheetPresentation: Equatable, Sendable {
    let preview: BulkProfileImportPreview

    var summaryText: String {
        if let issueSummary = preview.issueSummary {
            return issueSummary
        }

        return preview.entries.isEmpty ? "Paste account rows" : preview.countText
    }

    var submitTitle: String {
        switch preview.entries.count {
        case 0:
            return "Import"
        case 1:
            return "Import 1 profile"
        default:
            return "Import \(preview.entries.count) profiles"
        }
    }

    var isSubmitDisabled: Bool {
        preview.canSubmit == false
    }

    var tone: CodexStatusTone {
        if preview.issues.isEmpty == false {
            return .warning
        }

        return preview.entries.isEmpty ? .neutral : .success
    }
}

enum ProfilePrivateField: Hashable {
    case password
    case twoFactorCode
}

enum ProfileDetailsCopyField: Hashable, Sendable {
    case label
    case password
    case twoFactorCode
    case oneTimePassword
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

enum ProfileManagerPage: Equatable, Sendable {
    case profile
    case phoneSummary
}

struct ProfileManagerWindowView: View {
    @Bindable var controller: PlusProfileController
    let currentTime: AppMinuteClock
    @State private var detailsDraft = PlusProfileDetailsDraft()
    @State private var sidebarTagFilter = ProfileTagFilter()
    @State private var profileSearchQuery = ""
    @State private var isProfileSearchPresented = false
    @State private var revealedPrivateFields: Set<ProfilePrivateField> = []
    @State private var isOneTimePasswordRevealed = false
    @State private var oneTimePasswordCopyFailed = false
    @State private var copyFeedback = TransientValue<ProfileDetailsCopyField>()
    @State private var showsSavedConfirmation = false
    @State private var saveResetTask: Task<Void, Never>?
    @State private var showsBulkImportSheet = false
    @State private var bulkImportText = ""
    @State private var page = ProfileManagerPage.profile

    init(
        controller: PlusProfileController,
        currentTime: AppMinuteClock
    ) {
        self.controller = controller
        self.currentTime = currentTime
    }

    var body: some View {
        CodexWindowChromeContainer(minimumSize: CGSize(width: 1080, height: 760)) {
            VStack(alignment: .leading, spacing: CodexTheme.sectionSpacing) {
                header

                if let message = controller.statusMessage {
                    CodexStatusBanner(
                        title: controller.dashboardStatus.title,
                        message: message,
                        tone: controller.dashboardStatus.tone,
                        symbolName: controller.dashboardStatus.symbolName,
                        titleFont: ProfileManagerTypography.smallStrong,
                        messageFont: ProfileManagerTypography.small
                    )
                }

                bodyContent
            }
            .padding(.top, CodexTheme.chromePadding)
            .padding(.horizontal, CodexTheme.chromePadding)
            .padding(.bottom, CodexTheme.chromePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showsBulkImportSheet) {
            ProfileManagerBulkImportSheet(
                rawText: $bulkImportText,
                cancel: {
                    showsBulkImportSheet = false
                },
                submit: importBulkProfiles
            )
        }
        .onAppear {
            syncDrafts(with: controller.selectedProfile)
        }
        .onChange(of: controller.selectedProfileID) { _, _ in
            resetDetailsFeedback()
            syncDrafts(with: controller.selectedProfile)
        }
        .onChange(of: controller.profiles.map(\.id)) { _, _ in
            if controller.profiles.isEmpty {
                closeProfileSearch()
            }
        }
        .onChange(of: profileSearchQuery) { _, _ in
            keepSelectedProfileVisible()
        }
        .onChange(of: detailsDraft) { oldDraft, newDraft in
            guard let snapshot = controller.selectedProfile else {
                return
            }

            if oldDraft.twoFactorCode != newDraft.twoFactorCode {
                hideOneTimePassword()
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
                    .buttonStyle(CodexPrimaryButtonStyle(font: ProfileManagerTypography.smallStrong))
                    .disabled(controller.isRefreshing || controller.profiles.isEmpty)

                    Button(action: addProfile) {
                        Label("Add profile", systemImage: "plus")
                    }
                    .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.smallStrong))

                    Button(action: showBulkImport) {
                        Label("Import", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.smallStrong))
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

                    if controller.profiles.isEmpty == false {
                        Button(action: showProfileSearch) {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(CodexSecondaryButtonStyle())
                        .foregroundStyle(
                            isProfileSearchPresented
                                ? CodexTheme.searchAction
                                : CodexTheme.actionText
                        )
                        .accessibilityLabel("Search profiles")
                        .help("Search profiles")
                        .opacity(isProfileSearchPresented ? 0 : 1)
                        .allowsHitTesting(isProfileSearchPresented == false)
                        .accessibilityHidden(isProfileSearchPresented)
                    }

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
                    phoneSummaryNavigationButton

                    if isProfileSearchPresented {
                        ProfileSearchField(
                            text: $profileSearchQuery,
                            close: closeProfileSearch
                        )
                    }

                    ProfileTagFilterBar(
                        presentation: sidebarFilterPresentation,
                        clearFilter: clearSidebarFilter,
                        toggleTag: toggleSidebarFilter
                    )

                    if filteredSidebarProfiles.isEmpty,
                       ProfileSearch.normalizedQuery(profileSearchQuery).isEmpty == false {
                        ProfileSearchEmptyState(
                            query: profileSearchQuery,
                            clearsTagFilter: sidebarTagFilter.isEmpty == false,
                            clear: clearSearchAndSidebarFilter
                        )
                    } else if filteredSidebarProfiles.isEmpty {
                        ProfileTagEmptyState(clearFilter: clearSidebarFilter)
                    } else {
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredSidebarProfiles) { snapshot in
                                    Button {
                                        openProfile(snapshot.id)
                                    } label: {
                                        ProfileSummaryRow(
                                            snapshot: snapshot,
                                            referenceDate: currentTime.now,
                                            mode: .sidebar(
                                                isSelected: page == .profile
                                                    && snapshot.id == controller.selectedProfileID
                                            ),
                                            searchPhoneNumber: ProfileSearch.matchingPhoneNumber(
                                                in: snapshot,
                                                query: profileSearchQuery
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
        if page == .phoneSummary {
            PhoneSummaryView(
                presentation: phoneSummaryPresentation,
                referenceDate: currentTime.now,
                openProfile: openProfile
            )
        } else if let snapshot = controller.selectedProfile {
            let metrics = ProfileManagerDetailLayoutMetrics.chromeSignIn

            ScrollView(.vertical) {
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

    private var phoneSummaryNavigationButton: some View {
        Button {
            page = .phoneSummary
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "person.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        page == .phoneSummary
                            ? CodexTheme.utilityActionText
                            : CodexTheme.mutedText
                    )
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text(phoneSummaryPresentation.title)
                    .font(ProfileManagerTypography.smallStrong)
                    .foregroundStyle(CodexTheme.primaryText)

                Spacer(minLength: 8)

                if let countText = phoneSummaryPresentation.navigationCountText {
                    Text(countText)
                        .font(ProfileManagerTypography.caption)
                        .foregroundStyle(CodexTheme.dataValueText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(CodexTheme.surfaceFill(for: .nested))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        page == .phoneSummary
                            ? CodexTheme.surfaceFill(for: .nested)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(phoneSummaryPresentation.navigationAccessibilityLabel)
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
                    .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.smallStrong))
                    .disabled(formPresentation.isSaveEnabled == false)
                }
            }

            ProfileManagerDetailsTextField(
                title: "Profile label",
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
                text: $detailsDraft.password,
                presentation: ProfileManagerPrivateFieldPresentation(
                    title: "Password",
                    value: detailsDraft.password,
                    isRevealed: revealedPrivateFields.contains(.password),
                    isCopied: copyFeedback.current == .password
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
                title: "2FA key",
                text: $detailsDraft.twoFactorCode,
                presentation: ProfileManagerPrivateFieldPresentation(
                    title: "2FA key",
                    value: detailsDraft.twoFactorCode,
                    isRevealed: revealedPrivateFields.contains(.twoFactorCode),
                    isCopied: copyFeedback.current == .twoFactorCode
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

            if detailsDraft.twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                oneTimePasswordPanel
            }

            ProfileManagerPhoneNumberField(
                title: "Phone number",
                text: $detailsDraft.phoneNumber,
                savedNumbers: savedPhoneNumbers,
                onSubmit: {
                    saveDetailsDraftIfNeeded(for: snapshot)
                }
            ) {
                ProfileManagerInlineFieldActionButton(
                    title: copyFeedback.current == .phoneNumber ? "Copied" : "Copy",
                    symbolName: copyFeedback.current == .phoneNumber ? "checkmark" : "doc.on.doc",
                    helpText: phoneNumberCopyText.isEmpty ? "Add a phone number before copying it." : "Copy phone number",
                    accessibilityLabel: copyFeedback.current == .phoneNumber ? "Phone number copied" : "Copy phone number",
                    isDisabled: phoneNumberCopyText.isEmpty,
                    isConfirmed: copyFeedback.current == .phoneNumber,
                    action: {
                        copy(phoneNumberCopyText, field: .phoneNumber)
                    }
                )
            }

            ProfileManagerNotesDetailsField(
                title: "Notes",
                text: $detailsDraft.notes
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var oneTimePasswordPanel: some View {
        if isOneTimePasswordRevealed {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                oneTimePasswordPanelContent(referenceDate: context.date)
            }
        } else {
            oneTimePasswordPanelContent(referenceDate: currentTime.now)
        }
    }

    @ViewBuilder
    private func oneTimePasswordPanelContent(referenceDate: Date) -> some View {
        let presentation = ProfileManagerOneTimePasswordPresentation(
            secret: detailsDraft.twoFactorCode,
            isRevealed: isOneTimePasswordRevealed,
            isCopied: copyFeedback.current == .oneTimePassword,
            hasCopyError: oneTimePasswordCopyFailed,
            referenceDate: referenceDate
        )

        if presentation.isVisible {
            ProfileManagerOneTimePasswordPanel(
                presentation: presentation,
                reveal: revealOneTimePassword,
                hide: hideOneTimePassword,
                copy: copyOneTimePassword
            )
        }
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
                    .buttonStyle(CodexPrimaryButtonStyle(font: ProfileManagerTypography.smallStrong))
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
                    .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.smallStrong))
                    .disabled(presentation.isSyncDisabled)

                    if presentation.showsCancel {
                        Button(presentation.cancelTitle) {
                            closeChromeSignIn(snapshot.id)
                        }
                        .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.smallStrong))
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
        let orderedProfiles = PlusProfileSnapshot.expiryFirstDisplayOrder(
            sidebarTagFilter.apply(to: controller.profiles)
        )
        return ProfileSearch.filter(orderedProfiles, query: profileSearchQuery)
    }

    private var savedPhoneNumbers: [String] {
        ProfilePhoneNumberCatalog.savedNumbers(in: controller.profiles)
    }

    private var phoneSummaryPresentation: PhoneSummaryPresentation {
        PhoneSummaryPresentation(
            numberGroups: ProfilePhoneNumberCatalog.numberGroups(in: controller.profiles),
            profilesWithoutNumber: ProfilePhoneNumberCatalog.profilesWithoutNumber(
                in: controller.profiles
            )
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
            isCopied: copyFeedback.current == .label
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

        copyFeedback.show(field)
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
        copyFeedback.clear()
        revealedPrivateFields.removeAll()
        isOneTimePasswordRevealed = false
        oneTimePasswordCopyFailed = false
        resetSaveFeedback()
    }

    private func revealOneTimePassword() {
        oneTimePasswordCopyFailed = false
        isOneTimePasswordRevealed = true
    }

    private func hideOneTimePassword() {
        isOneTimePasswordRevealed = false
        oneTimePasswordCopyFailed = false
        if copyFeedback.current == .oneTimePassword {
            copyFeedback.clear()
        }
    }

    private func copyOneTimePassword() {
        do {
            let value = try ProfileManagerOneTimePasswordClipboardValue(
                secret: detailsDraft.twoFactorCode,
                referenceDate: .now
            )
            oneTimePasswordCopyFailed = false
            copy(value.text, field: .oneTimePassword)
        } catch {
            if copyFeedback.current == .oneTimePassword {
                copyFeedback.clear()
            }
            oneTimePasswordCopyFailed = true
        }
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
        page = .profile
        controller.addProfile()
    }

    private func showBulkImport() {
        showsBulkImportSheet = true
    }

    private func importBulkProfiles() {
        let preview = controller.importProfiles(from: bulkImportText)
        guard preview.canSubmit else {
            return
        }

        bulkImportText = ""
        showsBulkImportSheet = false
        page = .profile
        syncDrafts(with: controller.selectedProfile)
    }

    private func openProfile(_ profileID: UUID) {
        page = .profile
        controller.selectProfile(id: profileID)
    }

    private func clearSidebarFilter() {
        sidebarTagFilter.clear()
    }

    private func clearSearchAndSidebarFilter() {
        profileSearchQuery = ""
        sidebarTagFilter.clear()
        keepSelectedProfileVisible()
    }

    private func showProfileSearch() {
        isProfileSearchPresented = true
    }

    private func closeProfileSearch() {
        profileSearchQuery = ""
        isProfileSearchPresented = false
        keepSelectedProfileVisible()
    }

    private func toggleSidebarFilter(_ tag: PlusProfileTag) {
        sidebarTagFilter.toggle(tag)
        keepSelectedProfileVisible()
    }

    private func keepSelectedProfileVisible() {
        guard filteredSidebarProfiles.isEmpty == false else {
            return
        }

        if let selectedProfileID = controller.selectedProfileID,
           filteredSidebarProfiles.contains(where: { $0.id == selectedProfileID }) {
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

private struct ProfileManagerBulkImportSheet: View {
    @Binding var rawText: String
    let cancel: () -> Void
    let submit: () -> Void
    @FocusState private var isEditorFocused: Bool

    private var preview: BulkProfileImportPreview {
        BulkProfileImporter.preview(from: rawText)
    }

    private var presentation: ProfileManagerBulkImportSheetPresentation {
        ProfileManagerBulkImportSheetPresentation(preview: preview)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            importEditor

            if preview.issues.isEmpty == false {
                issueList
            }

            footer
        }
        .padding(22)
        .frame(width: 560, alignment: .topLeading)
        .background(CodexTheme.shellFill(for: .dialog))
        .onAppear {
            isEditorFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: CodexTheme.iconCornerRadius, style: .continuous)
                    .fill(presentation.tone.backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.iconCornerRadius, style: .continuous)
                            .stroke(presentation.tone.borderColor, lineWidth: 1)
                    )

                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(presentation.tone.foregroundColor)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Import profiles")
                    .font(ProfileManagerTypography.bodyStrong)
                    .foregroundStyle(CodexTheme.headingText)

                Text(presentation.summaryText)
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(presentation.tone == .warning ? CodexTheme.dangerText : CodexTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var importEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account rows")
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.dataLabelText)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $rawText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .foregroundStyle(CodexTheme.dataValueText)
                    .focused($isEditorFocused)

                if rawText.isEmpty {
                    Text("email|password|2FA")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(CodexTheme.quietText)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 210, maxHeight: 210)
            .background(ProfileManagerFieldBackground())
            .accessibilityLabel("Account rows")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(preview.issues.prefix(3), id: \.lineNumber) { issue in
                Label("Line \(issue.lineNumber): \(issue.message)", systemImage: "exclamationmark.triangle")
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(CodexTheme.dangerText)
            }

            if preview.issues.count > 3 {
                Text("\(preview.issues.count - 3) more lines need a fix")
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(CodexTheme.mutedText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .subtle), style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .subtle), style: .continuous)
                        .stroke(CodexTheme.accentRed.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(BulkProfileImporter.twoFactorLiveLink)
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.utilityActionText)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("Cancel") {
                cancel()
            }
            .buttonStyle(CodexSecondaryButtonStyle(font: ProfileManagerTypography.smallStrong))
            .keyboardShortcut(.cancelAction)

            Button {
                submit()
            } label: {
                Label(presentation.submitTitle, systemImage: "checkmark")
            }
            .buttonStyle(CodexPrimaryButtonStyle(font: ProfileManagerTypography.smallStrong))
            .disabled(presentation.isSubmitDisabled)
            .keyboardShortcut(.defaultAction)
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
                        tagTone: tag.profileTagTone,
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

private struct ProfileManagerPhoneNumberField<TrailingContent: View>: View {
    let title: String
    @Binding var text: String
    let savedNumbers: [String]
    let onSubmit: () -> Void
    let trailingContent: TrailingContent

    init(
        title: String,
        text: Binding<String>,
        savedNumbers: [String],
        onSubmit: @escaping () -> Void,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        self.title = title
        _text = text
        self.savedNumbers = savedNumbers
        self.onSubmit = onSubmit
        self.trailingContent = trailingContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(ProfileManagerTypography.caption)
                    .foregroundStyle(CodexTheme.dataLabelText)

                Spacer(minLength: 0)

                if savedNumbers.isEmpty == false {
                    Text(savedNumbers.count == 1 ? "1 saved" : "\(savedNumbers.count) saved")
                        .font(ProfileManagerTypography.micro)
                        .foregroundStyle(CodexTheme.supportText)
                        .accessibilityHidden(true)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                ProfilePhoneNumberComboBox(
                    text: $text,
                    savedNumbers: savedNumbers,
                    onSubmit: onSubmit
                )
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
                .background(ProfileManagerFieldBackground())

                trailingContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfileManagerDetailsTextField<TrailingContent: View>: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let trailingContent: TrailingContent

    init(
        title: String,
        text: Binding<String>,
        onSubmit: @escaping () -> Void,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        self.title = title
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
                TextField("", text: $text)
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
                        TextField("", text: $text)
                    } else {
                        SecureField("", text: $text)
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

private struct ProfileManagerOneTimePasswordPanel: View {
    let presentation: ProfileManagerOneTimePasswordPresentation
    let reveal: () -> Void
    let hide: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                        .fill(CodexTheme.surfaceFill(for: .subtle))
                        .overlay(
                            RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                                .stroke(presentation.tone.borderColor, lineWidth: 1)
                        )

                    Image(systemName: presentation.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(presentation.tone.foregroundColor)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.titleText)
                        .font(ProfileManagerTypography.caption)
                        .foregroundStyle(CodexTheme.dataLabelText)

                    Text(presentation.statusText)
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(
                            presentation.isCopyDisabled
                                ? presentation.tone.foregroundColor
                                : CodexTheme.oneTimePasswordStatusText
                        )
                }

                Spacer(minLength: 12)

                ZStack(alignment: .trailing) {
                    if presentation.isCodeMasked {
                        ProfileManagerOneTimePasswordMask()
                    } else {
                        Text(presentation.codeText)
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(
                                presentation.isCopyDisabled
                                    ? CodexTheme.disabledText
                                    : CodexTheme.oneTimePasswordCodeText
                            )
                    }
                }
                .frame(minWidth: 112, minHeight: 32, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityValue)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                ProfileManagerInlineFieldActionButton(
                    title: presentation.revealTitle,
                    symbolName: presentation.revealSymbolName,
                    helpText: oneTimePasswordRevealHelpText,
                    accessibilityLabel: oneTimePasswordRevealAccessibilityLabel,
                    isDisabled: false,
                    isConfirmed: false,
                    action: presentation.isRevealed ? hide : reveal
                )

                ProfileManagerInlineFieldActionButton(
                    title: presentation.copyTitle,
                    symbolName: presentation.copySymbolName,
                    helpText: oneTimePasswordCopyHelpText,
                    accessibilityLabel: oneTimePasswordCopyAccessibilityLabel,
                    isDisabled: presentation.isCopyDisabled,
                    isConfirmed: presentation.isCopied,
                    action: copy
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .subtle))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                        .fill(CodexTheme.surfaceSheen(for: .subtle))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var oneTimePasswordRevealHelpText: String {
        presentation.isRevealed ? "Hide current OTP" : "Show current OTP"
    }

    private var oneTimePasswordRevealAccessibilityLabel: String {
        presentation.isRevealed ? "Hide current OTP" : "Show current OTP"
    }

    private var oneTimePasswordCopyHelpText: String {
        presentation.isCopyDisabled ? "Add a valid 2FA key before copying the OTP." : "Copy current OTP"
    }

    private var oneTimePasswordCopyAccessibilityLabel: String {
        presentation.isCopied ? "OTP copied" : "Copy current OTP"
    }
}

private struct ProfileManagerOneTimePasswordMask: View {
    private let segmentWidths: [CGFloat] = [14, 12, 13, 12, 14, 12]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(segmentWidths.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(CodexTheme.oneTimePasswordMaskFill)
                    .frame(width: segmentWidths[index], height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.Radius.field, style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .nested))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.Radius.field, style: .continuous)
                .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

private struct ProfileManagerNotesDetailsField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.dataLabelText)

            TextEditor(text: $text)
                .font(ProfileManagerTypography.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(minHeight: 72, maxHeight: 108)
                .background(ProfileManagerFieldBackground())
                .foregroundStyle(CodexTheme.dataValueText)
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
