import AppKit
import SwiftUI
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct ProfileManagerWindowViewTests {
    @Test
    func dirtySameFieldWinsOnSaveWhileUntouchedFieldsRefresh() {
        var original = sampleProfile(label: "original", sortOrder: 0)
        original.password = "synthetic password"
        original.notes = "original note"
        let base = PlusProfileDetailsDraft(profile: original)
        var draft = base
        draft.notes = "unsaved local note"
        draft.password = ""
        var remote = original
        remote.label = "remote label"
        remote.notes = "remote note"
        remote.password = "different synthetic password"
        let latest = PlusProfileDetailsDraft(profile: remote)
        let refreshed = draft.refreshingUneditedFields(from: latest, base: base)
        #expect(refreshed.label == "remote label")
        #expect(refreshed.notes == "unsaved local note")
        #expect(refreshed.password.isEmpty)
        let saved = refreshed.applying(to: remote, base: latest)
        #expect(saved.label == "remote label")
        #expect(saved.notes == "unsaved local note")
        #expect(saved.password == nil)
    }

    @Test
    func draftSaveClearsOnlyEditedPasswordAndPreservesCurrentRemoteNotes() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileCatalogStore(fileURL: directory.appendingPathComponent("profiles.json"))
        var profile = sampleProfile(label: "synthetic", sortOrder: 0)
        profile.password = "synthetic password"
        profile.notes = "original note"
        try store.saveProfiles([profile])
        let controller = PlusProfileController(catalogStore: store, dataService: StubProfileViewDataService(), autoStart: false)
        let base = PlusProfileDetailsDraft(profile: profile)
        var draft = base
        draft.password = ""
        var current = profile
        current.notes = "remote note"
        current.phoneNumber = "123"
        current.lastKnownState = .needsLogin
        controller.profiles[0] = controller.profiles[0].updating(profile: current)
        try store.saveProfiles([current])

        #expect(controller.updateDetails(for: profile.id, draft: draft, base: base))
        let rows = try store.loadProfiles()
        let saved = try #require(rows.first)
        #expect(saved.password == nil)
        #expect(saved.notes == "remote note")
        #expect(saved.phoneNumber == "123")
        #expect(saved.webDataStoreID == profile.webDataStoreID)
        #expect(saved.lastKnownState == .needsLogin)
    }

    @Test
    func mountedDraftRefreshesUntouchedRemoteFieldWithoutSavingOldValuesOnNavigation() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileCatalogStore(fileURL: directory.appendingPathComponent("profiles.json"))
        var first = sampleProfile(label: "first", sortOrder: 0)
        first.notes = "original note"
        let second = sampleProfile(label: "second", sortOrder: 1)
        try store.saveProfiles([first, second])
        let controller = PlusProfileController(catalogStore: store, dataService: StubProfileViewDataService(), autoStart: false)
        let host = makeHostingView(controller: controller, initiallyShowsDetails: true)
        let window = hostInWindow(host)
        defer { window.orderOut(nil); window.contentView = nil }
        flushViewHierarchy(for: host)
        var remote = first
        remote.notes = "remote note"
        controller.profiles[0] = controller.profiles[0].updating(profile: remote)
        try store.saveProfiles([remote, second])
        flushViewHierarchy(for: host)
        let mountedEditor = host.allSubviews().compactMap { $0 as? NSTextView }.first(where: \.isEditable)
        let editor = try #require(mountedEditor)
        #expect(editor.string == "remote note")
        let keyboard = try #require(host.allSubviews().compactMap { $0 as? ProfileKeyboardView }.first)
        #expect(keyboard.handle?(.nextProfile) == true)
        #expect(controller.selectedProfileID == second.id)
        #expect(try store.loadProfiles().first?.notes == "remote note")
    }

    @Test
    func phoneSummaryPresentationAccountsForEveryProfile() {
        let first = sampleProfile(
            label: "alpha@example.com",
            phoneNumber: "+62 812 345",
            sortOrder: 0
        )
        let second = sampleProfile(
            label: "beta@example.com",
            phoneNumber: "+62-812-345",
            sortOrder: 1
        )
        let third = sampleProfile(
            label: "gamma@example.com",
            phoneNumber: "+63 966 111",
            sortOrder: 2
        )
        let fourth = sampleProfile(
            label: "delta@example.com",
            phoneNumber: nil,
            sortOrder: 3
        )
        let firstSnapshot = PlusProfileSnapshot(
            profile: first,
            state: .idle,
            usage: nil,
            statusMessage: nil,
            isRefreshing: false
        )
        let secondSnapshot = PlusProfileSnapshot(
            profile: second,
            state: .idle,
            usage: nil,
            statusMessage: nil,
            isRefreshing: false
        )
        let thirdSnapshot = PlusProfileSnapshot(
            profile: third,
            state: .idle,
            usage: nil,
            statusMessage: nil,
            isRefreshing: false
        )
        let fourthSnapshot = PlusProfileSnapshot(
            profile: fourth,
            state: .idle,
            usage: nil,
            statusMessage: nil,
            isRefreshing: false
        )
        let sharedGroup = ProfilePhoneNumberGroup(
            id: "62812345",
            phoneNumber: "+62 812 345",
            profiles: [firstSnapshot, secondSnapshot]
        )
        let singleUseGroup = ProfilePhoneNumberGroup(
            id: "63966111",
            phoneNumber: "+63 966 111",
            profiles: [thirdSnapshot]
        )

        let filled = PhoneSummaryPresentation(
            numberGroups: [sharedGroup, singleUseGroup],
            profilesWithoutNumber: [fourthSnapshot]
        )
        let empty = PhoneSummaryPresentation(
            numberGroups: [],
            profilesWithoutNumber: []
        )

        #expect(filled.title == "Phone summary")
        #expect(filled.totalProfileCount == 4)
        #expect(filled.sharedGroups == [sharedGroup])
        #expect(filled.singleUseGroups == [singleUseGroup])
        #expect(filled.summaryText == "2 profiles share a number. 1 profile uses a number once. 1 profile has no number.")
        #expect(filled.navigationCountText == "4")
        #expect(filled.navigationAccessibilityLabel == "Phone summary, 4 profiles")
        #expect(empty.summaryText == "No saved profiles yet.")
        #expect(empty.navigationCountText == nil)
        #expect(ProfileManagerPage.profile != .phoneSummary)
    }

    @Test
    func phoneSummaryExpiryPresentationShowsLiveAndMissingExpiry() {
        let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
        let live = PhoneSummaryExpiryPresentation(
            expiresAt: referenceDate.addingTimeInterval(TimeInterval((9 * 24 + 5) * 3_600)),
            referenceDate: referenceDate
        )
        let missing = PhoneSummaryExpiryPresentation(
            expiresAt: nil,
            referenceDate: referenceDate
        )

        #expect(live.value == DisplayFormatter.LabeledValue(label: "Expires in", value: "9d 5h"))
        #expect(live.accessibilityText == "Expires in 9d 5h")
        #expect(live.emphasisToken == CodexTheme.readableAccentToken(CodexTheme.Palette.accYellow))
        #expect(missing.value == DisplayFormatter.LabeledValue(label: nil, value: "Expiry unavailable"))
        #expect(missing.accessibilityText == "Expiry unavailable")
        #expect(missing.emphasisToken == nil)
    }

    @Test
    func sessionPaneNeverBuildsWKWebView() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        try store.saveProfiles([profile])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubProfileViewDataService(),
            autoStart: false
        )
        let hostingView = makeHostingView(controller: controller)

        let window = hostInWindow(hostingView)
        defer {
            window.orderOut(nil)
        }

        flushViewHierarchy(for: hostingView)

        #expect(containsWebView(in: hostingView) == false)
    }

    @Test
    func selectedProfileBuildsEditableFieldsWithSavedNotes() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        var profile = sampleProfile(
            label: "alpha@example.com",
            emailLink: "mail.google.com/mail/u/0/#inbox",
            sortOrder: 0
        )
        profile.notes = "Saved account note"
        try store.saveProfiles([profile])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubProfileViewDataService(),
            autoStart: false
        )
        let hostingView = makeHostingView(controller: controller, initiallyShowsDetails: true)
        let window = hostInWindow(hostingView)
        defer {
            window.orderOut(nil)
        }

        flushViewHierarchy(for: hostingView)

        #expect(editableTextFieldCount(in: hostingView) >= 5)
        #expect(textEditorCount(in: hostingView) == 1)

        let rootView = ProfileManagerWindowView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000))
        )
        let bodyType = String(reflecting: type(of: rootView.body))
        #expect(bodyType.contains("ProfileSearchField"))
        #expect(bodyType.contains("ProfileManagerPhoneNumberField"))
    }

    @Test(arguments: [nil, "", " \n\t"] as [String?])
    func emptyNotesDoNotMountAnEditor(notes: String?) throws {
        let store = ProfileCatalogStore(fileURL: makeTemporaryDirectory().appendingPathComponent("profiles.json"))
        var profile = sampleProfile(label: "studio@example.com", sortOrder: 0)
        profile.notes = notes
        try store.saveProfiles([profile])
        let controller = PlusProfileController(catalogStore: store, dataService: StubProfileViewDataService(), autoStart: false)
        let hostingView = makeHostingView(controller: controller, initiallyShowsDetails: true)
        let window = hostInWindow(hostingView)
        defer { window.orderOut(nil) }
        flushViewHierarchy(for: hostingView)

        #expect(editableTextFieldCount(in: hostingView) >= 5)
        #expect(textEditorCount(in: hostingView) == 0)
    }

    @Test
    func clearingSavedNotesKeepsTheSameEditorMounted() throws {
        let store = ProfileCatalogStore(fileURL: makeTemporaryDirectory().appendingPathComponent("profiles.json"))
        var profile = sampleProfile(label: "studio@example.com", sortOrder: 0)
        profile.notes = "Replace this note"
        try store.saveProfiles([profile])
        let controller = PlusProfileController(catalogStore: store, dataService: StubProfileViewDataService(), autoStart: false)
        let hostingView = makeHostingView(controller: controller, initiallyShowsDetails: true)
        let window = hostInWindow(hostingView)
        defer { window.orderOut(nil) }
        flushViewHierarchy(for: hostingView)
        let mountedEditor = hostingView.allSubviews().compactMap { $0 as? NSTextView }.first(where: \.isEditable)
        let editor = try #require(mountedEditor)
        window.makeFirstResponder(editor)
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        flushViewHierarchy(for: hostingView)

        #expect(editor.string.isEmpty)
        #expect(hostingView.allSubviews().contains(where: { $0 === editor }))
        editor.insertText("Replacement note", replacementRange: editor.selectedRange())
        flushViewHierarchy(for: hostingView)
        #expect(editor.string == "Replacement note")
    }

    @Test
    func selectingAnotherProfileResetsNotesDisclosureAndContent() throws {
        let store = ProfileCatalogStore(fileURL: makeTemporaryDirectory().appendingPathComponent("profiles.json"))
        var populated = sampleProfile(label: "notes@example.com", sortOrder: 0)
        populated.notes = "Notes belong to this profile"
        let empty = sampleProfile(label: "empty@example.com", sortOrder: 1)
        try store.saveProfiles([populated, empty])
        let controller = PlusProfileController(catalogStore: store, dataService: StubProfileViewDataService(), autoStart: false)
        controller.selectedProfileID = populated.id
        let hostingView = makeHostingView(controller: controller, initiallyShowsDetails: true)
        let window = hostInWindow(hostingView)
        defer { window.orderOut(nil) }
        flushViewHierarchy(for: hostingView)
        #expect(textEditorCount(in: hostingView) == 1)

        controller.selectedProfileID = empty.id
        flushViewHierarchy(for: hostingView)
        #expect(textEditorCount(in: hostingView) == 0)
        controller.selectedProfileID = populated.id
        flushViewHierarchy(for: hostingView)
        let editors = hostingView.allSubviews().compactMap { $0 as? NSTextView }.filter(\.isEditable)
        #expect(editors.map(\.string) == ["Notes belong to this profile"])
    }

    @Test
    func collapsedDetailsDoNotMountEditors() throws {
        let store = ProfileCatalogStore(fileURL: makeTemporaryDirectory().appendingPathComponent("profiles.json"))
        try store.saveProfiles([sampleProfile(label: "studio@example.com", sortOrder: 0)])
        let controller = PlusProfileController(catalogStore: store, dataService: StubProfileViewDataService(), autoStart: false)
        let hostingView = makeHostingView(controller: controller)
        let window = hostInWindow(hostingView)
        defer { window.orderOut(nil) }
        flushViewHierarchy(for: hostingView)
        #expect(editableTextFieldCount(in: hostingView) == 0)
        #expect(textEditorCount(in: hostingView) == 0)
    }

    @Test
    func emailLinkOpenButtonPresentationUsesInlineFieldActionState() {
        let profileWithEmail = sampleProfile(
            label: "alpha@example.com",
            emailLink: "mail.google.com/mail/u/0/#inbox",
            sortOrder: 0
        )
        let profileWithoutEmail = sampleProfile(
            label: "beta@example.com",
            emailLink: nil,
            sortOrder: 1
        )

        let enabled = ProfileManagerEmailLinkButtonPresentation(profile: profileWithEmail)
        let disabled = ProfileManagerEmailLinkButtonPresentation(profile: profileWithoutEmail)

        #expect(enabled.title == "Open")
        #expect(enabled.symbolName == "arrow.up.forward.square")
        #expect(enabled.isDisabled == false)
        #expect(enabled.helpText == "Open email link")

        #expect(disabled.title == "Open")
        #expect(disabled.symbolName == "arrow.up.forward.square")
        #expect(disabled.isDisabled)
        #expect(disabled.helpText == "Add an email link before opening it.")
    }

    @Test
    func labelCopyButtonPresentationUsesStableInlineStates() {
        let normal = ProfileManagerLabelCopyButtonPresentation(
            labelDraft: "  alpha@example.com  ",
            isCopied: false
        )
        let copied = ProfileManagerLabelCopyButtonPresentation(
            labelDraft: "alpha@example.com",
            isCopied: true
        )
        let empty = ProfileManagerLabelCopyButtonPresentation(
            labelDraft: "   ",
            isCopied: false
        )

        #expect(normal.title == "Copy")
        #expect(normal.symbolName == "doc.on.doc")
        #expect(normal.isDisabled == false)
        #expect(normal.copyText == "alpha@example.com")

        #expect(copied.title == "Copied")
        #expect(copied.symbolName == "checkmark")
        #expect(copied.isDisabled == false)

        #expect(empty.title == "Copy")
        #expect(empty.symbolName == "doc.on.doc")
        #expect(empty.isDisabled)
        #expect(empty.copyText == "")
    }

    @Test
    func privateFieldPresentationCopiesRealValueWithoutRevealingIt() {
        let hidden = ProfileManagerPrivateFieldPresentation(
            title: "Password",
            value: "secret-value",
            isRevealed: false,
            isCopied: false
        )
        let revealed = ProfileManagerPrivateFieldPresentation(
            title: "Password",
            value: "secret-value",
            isRevealed: true,
            isCopied: true
        )

        #expect(hidden.copyText == "secret-value")
        #expect(hidden.revealTitle == "Show")
        #expect(hidden.revealSymbolName == "eye")
        #expect(revealed.copyTitle == "Copied")
        #expect(revealed.revealTitle == "Hide")
        #expect(revealed.revealSymbolName == "eye.slash")
    }

    @Test
    func detailsFormPresentationShowsOneSaveActionOnlyWhenDirty() {
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let clean = ProfileManagerDetailsFormPresentation(
            draft: PlusProfileDetailsDraft(profile: profile),
            profile: profile,
            isSaved: false
        )
        var changedDraft = PlusProfileDetailsDraft(profile: profile)
        changedDraft.notes = "Temporary"
        let changed = ProfileManagerDetailsFormPresentation(
            draft: changedDraft,
            profile: profile,
            isSaved: false
        )
        let saved = ProfileManagerDetailsFormPresentation(
            draft: PlusProfileDetailsDraft(profile: profile),
            profile: profile,
            isSaved: true
        )

        #expect(clean.isSaveEnabled == false)
        #expect(changed.isSaveEnabled)
        #expect(changed.saveTitle == "Save changes")
        #expect(saved.saveTitle == "Saved")
        #expect(saved.saveSymbolName == "checkmark")
    }

    @Test(arguments: [
        "1. alpha@example.com|password-a|SECRETONE\n2. beta@example.com|password-b|SECRETTWO",
        "1. alpha@example.com\npassword-a\nSECRETONE\n\n2. beta@example.com\npassword-b\nSECRETTWO",
    ])
    func bulkImportSheetPresentationKeepsSubmitStateObvious(text: String) {
        let empty = ProfileManagerBulkImportSheetPresentation(
            preview: BulkProfileImporter.preview(from: "")
        )
        let valid = ProfileManagerBulkImportSheetPresentation(
            preview: BulkProfileImporter.preview(from: text)
        )
        let invalid = ProfileManagerBulkImportSheetPresentation(
            preview: BulkProfileImporter.preview(
                from: """
                alpha@example.com|password-a|SECRETONE
                beta@example.com|password-b
                """
            )
        )

        #expect(empty.summaryText == "Paste account rows")
        #expect(empty.submitTitle == "Import")
        #expect(empty.isSubmitDisabled)
        #expect(empty.tone == .neutral)

        #expect(valid.summaryText == "2 profiles ready")
        #expect(valid.submitTitle == "Import 2 profiles")
        #expect(valid.isSubmitDisabled == false)
        #expect(valid.tone == .success)

        #expect(invalid.summaryText == "Fix line 2")
        #expect(invalid.submitTitle == "Import 1 profile")
        #expect(invalid.isSubmitDisabled)
        #expect(invalid.tone == .warning)
    }

    @Test
    func detailLayoutKeepsChromeSignInCardCompact() {
        let metrics = ProfileManagerDetailLayoutMetrics.chromeSignIn

        #expect(metrics.detailStackSpacing < CodexTheme.contentSpacing)
        #expect(metrics.compactCardPadding < CodexTheme.panelPadding)
        #expect(metrics.usageMetricTextScale >= 1)
    }

    @Test
    func filterPresentationShowsFilteredCountForManagerSidebar() {
        let presentation = ProfileFilterBarPresentation(
            filter: ProfileFilter([.active]),
            shownCount: 2,
            totalCount: 5,
            limitCounts: ProfileLimitCounts(usable: 4, aboveThirtyFive: 2, fullFiveHour: 1),
            tagCounts: ProfileTagCounts(active: 2, needAction: 1, pending: 2)
        )

        #expect(presentation.countText == "2 of 5 shown")
        #expect(presentation.visibleSummaryText == "2 of 5 shown")
        #expect(
            presentation.accessibilitySummaryText
                == "2 of 5 shown, Active status"
        )
        #expect(presentation.statusCountText == "2 active · 1 need action · 2 pending")
        #expect(presentation.isAllSelected == false)
        #expect(presentation.isSelected(.fullFiveHour) == false)
        #expect(presentation.isSelected(.active))
        #expect(presentation.isSelected(.pending) == false)
    }

    @Test
    func filterPresentationExposesProviderSegmentsAndSelection() throws {
        let presentation = ProfileFilterBarPresentation(
            filter: ProfileFilter(provider: .codex),
            shownCount: 5,
            totalCount: 5,
            providerCounts: ProfileProviderCounts(codex: 5)
        )

        #expect(
            presentation.segments.prefix(2).map(\.displayText)
                == ["All 5", "Codex 5"]
        )
        let codex = try #require(
            presentation.segments.first { $0.kind == .provider(.codex) }
        )
        #expect(codex.isSelected)
        #expect(codex.accessibilityLabel == "Codex profiles")
        #expect(presentation.accessibilitySummaryText.contains("Codex only"))
        #expect(presentation.controlSummaryText == "Codex · 5 profiles")
    }

    @Test
    func chromeSessionPresentationUsesCompactActionState() {
        let snapshot = PlusProfileSnapshot(
            profile: sampleProfile(label: "alpha@example.com", sortOrder: 0),
            state: .needsLogin,
            usage: nil,
            statusMessage: nil,
            isRefreshing: false
        )

        let waiting = ProfileManagerSessionPanelPresentation(
            snapshot: snapshot,
            isChromeSignInOpen: true
        )
        let idle = ProfileManagerSessionPanelPresentation(
            snapshot: snapshot,
            isChromeSignInOpen: false
        )

        #expect(waiting.title == "Codex sign-in")
        #expect(waiting.summaryText == "Sign in, then return here. Usage updates automatically.")
        #expect(waiting.primaryTitle == "Show Codex")
        #expect(waiting.passkeyHelpTitle == "Touch ID help")
        #expect(waiting.syncTitle == "Check now")
        #expect(waiting.cancelTitle == "Cancel")
        #expect(waiting.showsSync)
        #expect(waiting.isSyncDisabled == false)
        #expect(waiting.showsCancel)
        #expect(waiting.showsPasskeyHelp)
        #expect(idle.summaryText == "Open Codex to sign in.")
        #expect(idle.showsSync == false)
        #expect(idle.isSyncDisabled)
        #expect(idle.showsCancel == false)

        let readyCodex = ProfileManagerSessionPanelPresentation(
            snapshot: snapshot.updating(
                state: .ready,
                usage: .some(
                    PlusProfileUsage(
                        accountID: "841724c1-1111-4222-8333-123456789abc",
                        planType: "plus",
                        primaryWindow: WorkspaceLimitWindow(
                            usedPercent: 25,
                            resetAt: Date(timeIntervalSince1970: 1_776_000_900)
                        ),
                        secondaryWindow: nil,
                        fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
                    )
                ),
                statusMessage: .some("Waiting for Codex sign-in in Chrome.")
            ),
            isChromeSignInOpen: true
        )
        #expect(readyCodex.summaryText == "Codex session is synced.")
        #expect(readyCodex.primaryTitle == "Show Codex")
        #expect(readyCodex.showsSync == false)
        #expect(readyCodex.showsCancel == false)
    }

    @Test(arguments: ["nextReset", "nextSevenDayReset"])
    func resetSortPreferenceIsSharedByBothListsWithoutChangingSavedProfiles(_ rawOrder: String) throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let store = ProfileCatalogStore(fileURL: tempDirectory.appendingPathComponent("profiles.json"))
        let fiveHourSoon = sampleProfile(label: "five-hour@example.com", sortOrder: 0)
        let sevenDaySoon = sampleProfile(label: "seven-day@example.com", sortOrder: 1)
        let savedProfiles = [fiveHourSoon, sevenDaySoon]
        try store.saveProfiles(savedProfiles)
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubProfileViewDataService(),
            autoStart: false
        )
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        controller.profiles = savedProfiles.enumerated().map { index, profile in
            PlusProfileSnapshot(
                profile: profile,
                state: .ready,
                usage: PlusProfileUsage(
                    accountID: "account-\(index)",
                    planType: "test",
                    primaryWindow: WorkspaceLimitWindow(
                        usedPercent: 50,
                        resetAt: now.addingTimeInterval(index == 0 ? 3_600 : 7_200)
                    ),
                    secondaryWindow: WorkspaceLimitWindow(
                        usedPercent: 50,
                        resetAt: now.addingTimeInterval(index == 0 ? 172_800 : 86_400)
                    ),
                    fetchedAt: now
                ),
                statusMessage: nil,
                isRefreshing: false
            )
        }
        controller.selectedProfileID = fiveHourSoon.id
        let originalSnapshots = controller.profiles
        let suiteName = "ProfileManagerWindowViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(rawOrder, forKey: ProfileDisplayOrderPreference.orderKey)
        let clock = AppMinuteClock(now: now)
        let manager = ProfileManagerWindowView(
            controller: controller, currentTime: clock, userDefaults: defaults
        )
        let panel = MenuBarRootView(
            controller: controller, currentTime: clock, userDefaults: defaults,
            openManagerWindow: { _ in }, openEmailToolsWindow: {}
        )
        let expectedIDs = rawOrder == "nextReset"
            ? [fiveHourSoon.id, sevenDaySoon.id]
            : [sevenDaySoon.id, fiveHourSoon.id]

        #expect(manager.filteredSidebarProfiles.map(\.id) == expectedIDs)
        #expect(panel.displayProfiles(for: ProfileFilter()).map(\.id) == expectedIDs)
        #expect(controller.profiles == originalSnapshots)
        #expect(controller.selectedProfileID == fiveHourSoon.id)
        #expect(try store.loadProfiles() == savedProfiles)
    }

    @Test
    func sidebarUsesExpiryFirstDisplayOrderWithoutChangingControllerStorageOrder() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "unknown@example.com", sortOrder: 0)
        let second = sampleProfile(label: "later@example.com", sortOrder: 1)
        let third = sampleProfile(label: "soonest@example.com", sortOrder: 2)
        try store.saveProfiles([first, second, third])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubProfileViewDataService(),
            autoStart: false
        )
        let defaultsSuiteName = "ProfileManagerWindowViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        ProfileDisplayOrderPreference.setOrder(.accountExpiry, defaults: defaults)
        controller.profiles = [
            PlusProfileSnapshot(
                profile: first,
                state: .ready,
                usage: nil,
                statusMessage: nil,
                isRefreshing: false
            ),
            PlusProfileSnapshot(
                profile: {
                    var profile = second
                    profile.expiresAt = Date(timeIntervalSince1970: 1_781_049_600)
                    return profile
                }(),
                state: .ready,
                usage: nil,
                statusMessage: nil,
                isRefreshing: false
            ),
            PlusProfileSnapshot(
                profile: {
                    var profile = third
                    profile.expiresAt = Date(timeIntervalSince1970: 1_780_876_800)
                    return profile
                }(),
                state: .ready,
                usage: nil,
                statusMessage: nil,
                isRefreshing: false
            ),
        ]

        let view = ProfileManagerWindowView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
            userDefaults: defaults
        )

        #expect(controller.profiles.map(\.label) == [
            "unknown@example.com",
            "later@example.com",
            "soonest@example.com",
        ])
        #expect(view.filteredSidebarProfiles.map(\.label) == [
            "soonest@example.com",
            "later@example.com",
            "unknown@example.com",
        ])
    }
}

@MainActor
private final class StubProfileViewDataService: PlusProfileDataServing {
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        fatalError("Not used in ProfileManagerWindowViewTests")
    }

    func openChromeSignIn(for profile: PlusProfile) async throws {
    }

    func openChromeAccountPage(for profile: PlusProfile) async throws {
    }

    func openChromePasskeySetup(for profile: PlusProfile) async throws {
    }

    func syncChromeSession(for profile: PlusProfile) async throws {
    }

    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool {
        false
    }

    func closeChromeSignIn(for profile: PlusProfile) async {
    }

    func clearSession(for profile: PlusProfile) async throws {
    }

    func removeProfileData(for profile: PlusProfile) async throws {
    }
}

@MainActor
private func containsWebView(in rootView: NSView) -> Bool {
    rootView.allSubviews().contains(where: { $0 is WKWebView })
}

@MainActor
private func makeHostingView(
    controller: PlusProfileController,
    initiallyShowsDetails: Bool = false
) -> NSHostingView<ProfileManagerWindowView> {
    let hostingView = NSHostingView(
        rootView: ProfileManagerWindowView(
            controller: controller,
            currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
            initiallyShowsDetails: initiallyShowsDetails
        )
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
    return hostingView
}

@MainActor
private func hostInWindow(_ hostingView: NSHostingView<ProfileManagerWindowView>) -> NSWindow {
    let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    return window
}

@MainActor
private func flushViewHierarchy(for hostingView: NSHostingView<ProfileManagerWindowView>) {
    hostingView.layoutSubtreeIfNeeded()

    for _ in 0..<3 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
    }
}

private func sampleProfile(
    label: String,
    emailLink: String? = nil,
    phoneNumber: String? = nil,
    sortOrder: Int
) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: label,
        emailLink: emailLink,
        detectedNote: nil,
        phoneNumber: phoneNumber,
        tags: [],
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private extension NSView {
    func allSubviews() -> [NSView] {
        var descendants: [NSView] = []

        for child in subviews {
            descendants.append(child)
            descendants.append(contentsOf: child.allSubviews())
        }

        return descendants
    }
}

@MainActor
private func editableTextFieldCount(in rootView: NSView) -> Int {
    rootView.allSubviews()
        .compactMap { $0 as? NSTextField }
        .filter(\.isEditable)
        .count
}

@MainActor
private func textEditorCount(in rootView: NSView) -> Int {
    rootView.allSubviews()
        .compactMap { $0 as? NSTextView }
        .filter(\.isEditable)
        .count
}
