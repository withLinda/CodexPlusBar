import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct PlusProfileControllerTests {
    @Test
    func loadingRepairsDuplicateProfileIdentifiersAndKeepsCurrentCopy() throws {
        let tempDirectory = makeTemporaryDirectory()
        let fileURL = tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        let store = ProfileCatalogStore(fileURL: fileURL)
        var current = sampleProfile(label: "current@example.com", sortOrder: 0)
        current.phoneNumber = "+62 812 3456"
        current.notes = "Keep this current copy"
        var staleDuplicate = current
        staleDuplicate.sortOrder = 1
        staleDuplicate.phoneNumber = nil
        staleDuplicate.notes = nil
        let data = try JSONEncoder().encode([current, staleDuplicate])
        try data.write(to: fileURL, options: .atomic)

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )

        let row = try #require(controller.profiles.first)
        #expect(controller.profiles.count == 1)
        #expect(row.id == current.id)
        #expect(row.profile.phoneNumber == current.phoneNumber)
        #expect(row.profile.notes == current.notes)
        #expect(controller.statusMessage == "Fixed 1 duplicate saved profile.")
        #expect(try store.loadProfiles().count == 1)
    }

    @Test
    func persistenceRemovesDuplicateSnapshotsBeforeSaving() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "current@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )
        let snapshot = try #require(controller.profiles.first)
        controller.profiles.append(snapshot)

        controller.setTags([.active], for: profile.id)

        #expect(controller.profiles.count == 1)
        #expect(controller.profiles.first?.tags == [.active])
        #expect(try store.loadProfiles().count == 1)
    }

    @Test
    func refreshAllUpdatesEachProfileWithoutCollapsingOtherRows() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let second = sampleProfile(label: "beta@example.com", sortOrder: 1)
        try store.saveProfiles([first, second])

        let firstUsage = makeUsage(accountID: "acct_alpha", primaryUsedPercent: 22, secondaryUsedPercent: 35)
        let service = StubPlusProfileDataService(
            refreshResults: [
                first.id: .success(
                    PlusProfileRefreshResult(
                        usage: firstUsage,
                        detectedNote: "Chatgpt Plus · alpha",
                        expiryRefresh: .value(Date(timeIntervalSince1970: 1_779_097_600))
                    )
                ),
                second.id: .failure(.unauthorized),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.refreshAll()

        let rows = controller.profiles
        #expect(rows.count == 2)
        #expect(rows[0].state == .ready)
        #expect(rows[0].usage?.primaryWindow.remainingPercent == 78)
        #expect(rows[0].profile.detectedNote == "Chatgpt Plus · alpha")
        #expect(rows[0].profile.expiresAt == Date(timeIntervalSince1970: 1_779_097_600))
        #expect(rows[1].state == .needsLogin)
        #expect(rows[1].usage == nil)

        let persisted = try store.loadProfiles()
        #expect(persisted[0].lastKnownState == .active)
        #expect(persisted[1].lastKnownState == .needsLogin)
    }

    @Test
    func refreshAllUsesAtMostThreeConcurrentProfiles() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profiles = (0..<6).map { index in
            sampleProfile(label: "account-\(index + 1)@example.com", sortOrder: index)
        }
        try store.saveProfiles(profiles)

        let service = ConcurrencyRecordingProfileDataService(delayNanoseconds: 50_000_000)
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.refreshAll()

        #expect(await service.maxConcurrent == 3)
    }

    @Test
    func clearSessionKeepsProfileButMarksItForLogin() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        try store.saveProfiles([profile])

        let service = StubPlusProfileDataService(
            refreshResults: [
                profile.id: .success(
                    PlusProfileRefreshResult(
                        usage: makeUsage(accountID: "acct_alpha", primaryUsedPercent: 25, secondaryUsedPercent: 40),
                        detectedNote: "Chatgpt Plus · alpha",
                        expiryRefresh: .value(Date(timeIntervalSince1970: 1_779_097_600))
                    )
                ),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.refreshAll()
        await controller.clearSession(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(row.state == .needsLogin)
        #expect(row.usage == nil)
        #expect(service.clearedProfileIDs == [profile.id])
        #expect(try store.loadProfiles().first?.lastKnownState == .needsLogin)
    }

    @Test
    func openChromeSignInMarksProfileAsWaitingForChrome() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "chrome@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let service = StubPlusProfileDataService(refreshResults: [:])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.openChrome(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(service.openedChromeProfileIDs == [profile.id])
        #expect(controller.isChromeSignInOpen(for: profile.id))
        #expect(service.waitedForChromeProfileIDs == [profile.id])
        #expect(row.statusMessage == "Sign in, then return here. Usage updates automatically.")
    }

    @Test
    func readyCodexOpenUsesAccountPageWithoutStartingSignInFlow() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "ready@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let usage = makeUsage(
            accountID: "acct_ready",
            primaryUsedPercent: 24,
            secondaryUsedPercent: 38
        )
        let service = StubPlusProfileDataService(
            refreshResults: [
                profile.id: .success(
                    PlusProfileRefreshResult(
                        usage: usage,
                        detectedNote: "Chatgpt Plus · ready",
                        expiryRefresh: .unchanged
                    )
                ),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.refreshAll()
        await controller.openChrome(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(service.openedChromeAccountPageProfileIDs == [profile.id])
        #expect(service.openedChromeProfileIDs.isEmpty)
        #expect(service.waitedForChromeProfileIDs.isEmpty)
        #expect(service.syncedChromeProfileIDs.isEmpty)
        #expect(controller.isChromeSignInOpen(for: profile.id) == false)
        #expect(row.state == .ready)
        #expect(row.usage?.accountID == usage.accountID)
        #expect(row.statusMessage == nil)
    }

    @Test
    func claudeOpenUsesSavedSessionAndOpensItsAccountPage() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        var profile = sampleProfile(label: "claude@example.com", sortOrder: 0)
        profile.provider = .claude
        profile.lastKnownState = .needsLogin
        try store.saveProfiles([profile])
        let usage = makeUsage(
            accountID: "841724c1-1111-4222-8333-123456789abc",
            primaryUsedPercent: 18,
            secondaryUsedPercent: 0
        )
        let service = StubPlusProfileDataService(
            refreshResults: [
                profile.id: .success(
                    PlusProfileRefreshResult(
                        usage: usage,
                        detectedNote: "Claude",
                        expiryRefresh: .unchanged
                    )
                ),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.openChrome(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(row.state == .ready)
        #expect(row.usage?.accountID == usage.accountID)
        #expect(service.openedChromeAccountPageProfileIDs == [profile.id])
        #expect(service.openedChromeProfileIDs.isEmpty)
        #expect(service.waitedForChromeProfileIDs.isEmpty)
        #expect(controller.isChromeSignInOpen(for: profile.id) == false)
    }

    @Test
    func returningFromSignInBrowserAutomaticallySyncsAndRefreshesUsage() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "auto-close@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let usage = makeUsage(
            accountID: "acct_auto_close",
            primaryUsedPercent: 22,
            secondaryUsedPercent: 31
        )
        let service = StubPlusProfileDataService(
            refreshResults: [
                profile.id: .success(
                    PlusProfileRefreshResult(
                        usage: usage,
                        detectedNote: "Chatgpt Plus · close",
                        expiryRefresh: .unchanged
                    )
                ),
            ],
            syncResults: [
                profile.id: .success(
                    ChatGPTAuthContext(
                        accessToken: "token-auto-close",
                        accountID: "acct_auto_close",
                        expiresAt: nil,
                        deviceID: nil,
                        clientVersion: nil,
                        language: "en-US"
                    )
                ),
            ],
            chromeSignInFinishResults: [profile.id: true]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.openChrome(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(service.openedChromeProfileIDs == [profile.id])
        #expect(service.waitedForChromeProfileIDs == [profile.id])
        #expect(service.syncedChromeProfileIDs == [profile.id])
        #expect(controller.isChromeSignInOpen(for: profile.id) == false)
        #expect(row.state == .ready)
        #expect(row.usage?.accountID == "acct_auto_close")
    }

    @Test
    func changingProviderClosesOldSignInAndPersistsClaude() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "switch@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let service = StubPlusProfileDataService(refreshResults: [:])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.openChrome(for: profile.id)
        let didChange = await controller.setProvider(.claude, for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(didChange)
        #expect(row.profile.provider == .claude)
        #expect(row.profile.detectedNote == nil)
        #expect(row.state == .needsLogin)
        #expect(row.usage == nil)
        #expect(row.statusMessage == "Open Chrome to sign in to Claude.")
        #expect(controller.isChromeSignInOpen(for: profile.id) == false)
        #expect(service.closedChromeProfileIDs == [profile.id])
        #expect(try store.loadProfiles().first?.provider == .claude)
    }

    @Test
    func openChromePasskeySetupShowsShortTouchIDHelpAndCanCancel() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "touchid@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let service = StubPlusProfileDataService(refreshResults: [:])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.openChromePasskeySetup(for: profile.id)

        var row = try #require(controller.profiles.first)
        #expect(service.openedPasskeySetupProfileIDs == [profile.id])
        #expect(controller.isChromeSignInOpen(for: profile.id))
        #expect(row.statusMessage == PlusProfileController.touchIDPasskeyHelpMessage)

        await controller.closeChromeSignIn(for: profile.id)

        row = try #require(controller.profiles.first)
        #expect(service.closedChromeProfileIDs == [profile.id])
        #expect(controller.isChromeSignInOpen(for: profile.id) == false)
        #expect(row.statusMessage == "Chrome sign-in was cancelled.")
    }

    @Test
    func syncChromeSessionRefreshesProfileAndClearsWaitingState() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "chrome@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let usage = makeUsage(accountID: "acct_chrome", primaryUsedPercent: 30, secondaryUsedPercent: 45)
        let service = StubPlusProfileDataService(
            refreshResults: [
                profile.id: .success(
                    PlusProfileRefreshResult(
                        usage: usage,
                        detectedNote: "Chatgpt Plus · chrome",
                        expiryRefresh: .unchanged
                    )
                ),
            ],
            syncResults: [
                profile.id: .success(
                    ChatGPTAuthContext(
                        accessToken: "token-chrome",
                        accountID: "acct_chrome",
                        expiresAt: nil,
                        deviceID: "device-a",
                        clientVersion: nil,
                        language: "en-US"
                    )
                ),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.openChrome(for: profile.id)
        await controller.syncChromeSession(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(service.syncedChromeProfileIDs == [profile.id])
        #expect(controller.isChromeSignInOpen(for: profile.id) == false)
        #expect(row.state == .ready)
        #expect(row.usage?.accountID == "acct_chrome")
        #expect(row.statusMessage == nil)
    }

    @Test
    func syncChromeSessionWithoutSessionKeepsChromeFlowOpen() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "chrome@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let service = StubPlusProfileDataService(
            refreshResults: [:],
            syncResults: [
                profile.id: .failure(.unauthorized),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.openChrome(for: profile.id)
        await controller.syncChromeSession(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(controller.isChromeSignInOpen(for: profile.id))
        #expect(row.state == .needsLogin)
        #expect(row.statusMessage == "Codex session was not ready. Stay signed in, then sync again.")
        #expect(row.isRefreshing == false)
    }

    @Test
    func updateDetailsPersistsAllFieldsWithoutChangingRuntimeStateOrOrder() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "old@example.com", sortOrder: 0)
        let second = sampleProfile(label: "second@example.com", sortOrder: 1)
        try store.saveProfiles([first, second])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )
        let originalState = try #require(controller.profiles.first?.state)

        let didSave = controller.updateDetails(
            for: first.id,
            draft: PlusProfileDetailsDraft(
                label: "new@example.com",
                emailLink: " mail.example.com ",
                password: "secret",
                twoFactorCode: "JBSWY3DP",
                phoneNumber: "+62 812",
                notes: "Temporary"
            )
        )

        let row = try #require(controller.profiles.first)
        let persisted = try store.loadProfiles()
        #expect(didSave)
        #expect(persisted.map(\.id) == [first.id, second.id])
        #expect(row.state == originalState)
        #expect(row.profile.label == "new@example.com")
        #expect(row.profile.emailLink == "mail.example.com")
        #expect(row.profile.password == "secret")
        #expect(persisted.first?.twoFactorCode == "JBSWY3DP")
        #expect(persisted.first?.phoneNumber == "+62 812")
        #expect(persisted.first?.notes == "Temporary")
    }

    @Test
    func updateDetailsKeepsSavedProfileAndReportsFailureWhenDiskWriteFails() throws {
        let tempDirectory = makeTemporaryDirectory()
        let fileURL = tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        let store = ProfileCatalogStore(fileURL: fileURL)
        let profile = sampleProfile(label: "old@example.com", sortOrder: 0)
        try store.saveProfiles([profile])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )
        try FileManager.default.removeItem(at: tempDirectory)
        try Data().write(to: tempDirectory)

        var draft = PlusProfileDetailsDraft(profile: profile)
        draft.label = "new@example.com"
        let didSave = controller.updateDetails(for: profile.id, draft: draft)

        #expect(didSave == false)
        #expect(controller.profiles.first?.profile.label == "old@example.com")
        #expect(controller.statusMessage == "The profile list could not be saved locally.")
    }

    @Test
    func updateDetailsPersistsTrimmedEmailLinkWithoutChangingOrdering() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let second = sampleProfile(label: "beta@example.com", sortOrder: 1)
        try store.saveProfiles([first, second])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )

        var draft = PlusProfileDetailsDraft(profile: first)
        draft.emailLink = "  mail.google.com/mail/u/0/#inbox  "
        let didSave = controller.updateDetails(for: first.id, draft: draft)

        let persisted = try store.loadProfiles()
        #expect(didSave)
        #expect(persisted.map(\.id) == [first.id, second.id])
        #expect(controller.profiles.first?.profile.emailLink == "mail.google.com/mail/u/0/#inbox")
        #expect(persisted.first?.emailLink == "mail.google.com/mail/u/0/#inbox")
        #expect(persisted.last?.emailLink == nil)
    }

    @Test
    func importProfilesCreatesSavedRowsWithTwoFactorLiveLinkAndPrivateFields() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let existing = sampleProfile(label: "existing@example.com", sortOrder: 0)
        try store.saveProfiles([existing])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )

        let preview = controller.importProfiles(
            from: """
            alpha+one@icloud.com|first-password|FIRST2FASECRET
            beta-two@icloud.com|second-password|SECOND2FASECRET
            """
        )

        let rows = controller.profiles
        let persisted = try store.loadProfiles()
        #expect(preview.canSubmit)
        #expect(preview.entries.count == 2)
        #expect(rows.map(\.label) == [
            "existing@example.com",
            "alpha+one@icloud.com",
            "beta-two@icloud.com",
        ])
        #expect(rows[1].profile.emailLink == BulkProfileImporter.twoFactorLiveLink)
        #expect(rows[1].profile.password == "first-password")
        #expect(rows[1].profile.twoFactorCode == "FIRST2FASECRET")
        #expect(rows[1].state == .idle)
        #expect(rows[1].statusMessage == "Open Chrome to sign in with this account.")
        #expect(controller.selectedProfileID == rows[1].id)
        #expect(controller.statusMessage == "Imported 2 profiles.")
        #expect(persisted.map(\.sortOrder) == [0, 1, 2])
        #expect(persisted[2].emailLink == BulkProfileImporter.twoFactorLiveLink)
        #expect(persisted[2].password == "second-password")
        #expect(persisted[2].twoFactorCode == "SECOND2FASECRET")
    }

    @Test
    func importProfilesDoesNotPersistWhenAnyLineNeedsFixing() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let existing = sampleProfile(label: "existing@example.com", sortOrder: 0)
        try store.saveProfiles([existing])
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )

        let preview = controller.importProfiles(
            from: """
            alpha+one@icloud.com|first-password|FIRST2FASECRET
            beta-two@icloud.com|second-password
            """
        )

        #expect(preview.canSubmit == false)
        #expect(preview.issueSummary == "Fix line 2")
        #expect(controller.profiles.map(\.label) == ["existing@example.com"])
        #expect(try store.loadProfiles().map(\.label) == ["existing@example.com"])
        #expect(controller.statusMessage == "Fix line 2")
    }

    @Test
    func updateDetailsNormalizesBlankEmailLinkToNil() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(
            label: "alpha@example.com",
            sortOrder: 0,
            emailLink: "https://mail.google.com"
        )
        try store.saveProfiles([profile])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )

        var draft = PlusProfileDetailsDraft(profile: profile)
        draft.emailLink = "   "
        let didSave = controller.updateDetails(for: profile.id, draft: draft)

        #expect(didSave)
        #expect(controller.profiles.first?.profile.emailLink == nil)
        #expect(try store.loadProfiles().first?.emailLink == nil)
    }

    @Test
    func toggleTagPersistsTagsWithoutChangingRuntimeState() throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        try store.saveProfiles([profile])

        let controller = PlusProfileController(
            catalogStore: store,
            dataService: StubPlusProfileDataService(refreshResults: [:]),
            autoStart: false
        )
        let initialState = try #require(controller.profiles.first?.state)
        let initialMessage = controller.profiles.first?.statusMessage

        controller.toggleTag(.pending, for: profile.id)
        controller.toggleTag(.active, for: profile.id)
        controller.toggleTag(.pending, for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(row.profile.tags == [.active])
        #expect(row.state == initialState)
        #expect(row.statusMessage == initialMessage)
        #expect(try store.loadProfiles().first?.tags == [.active])
    }

    @Test
    func profileFilterCombinesTagsWithOneClearLimitMode() {
        let active = menuBarSnapshot(
            label: "active@example.com",
            state: .ready,
            fiveHourRemainingPercent: 74,
            sevenDayRemainingPercent: 42,
            sortOrder: 0,
            tags: [.active]
        )
        let pending = menuBarSnapshot(
            label: "pending@example.com",
            state: .needsLogin,
            fiveHourRemainingPercent: nil,
            sevenDayRemainingPercent: nil,
            sortOrder: 1,
            tags: [.pending]
        )
        let mixed = menuBarSnapshot(
            label: "mixed@example.com",
            state: .failed,
            fiveHourRemainingPercent: nil,
            sevenDayRemainingPercent: nil,
            sortOrder: 2,
            tags: [.needAction, .pending]
        )
        let untagged = menuBarSnapshot(
            label: "untagged@example.com",
            state: .ready,
            fiveHourRemainingPercent: 32,
            sevenDayRemainingPercent: 18,
            sortOrder: 3,
            tags: []
        )
        let fullActive = menuBarSnapshot(
            label: "full-active@example.com",
            state: .ready,
            fiveHourRemainingPercent: 100,
            sevenDayRemainingPercent: 42,
            sortOrder: 4,
            tags: [.active]
        )
        let fullPending = menuBarSnapshot(
            label: "full-pending@example.com",
            state: .ready,
            fiveHourRemainingPercent: 100,
            sevenDayRemainingPercent: nil,
            sortOrder: 5,
            tags: [.pending]
        )
        let secondaryFullOnly = menuBarSnapshot(
            label: "secondary-full@example.com",
            state: .ready,
            fiveHourRemainingPercent: 74,
            sevenDayRemainingPercent: 100,
            sortOrder: 6,
            tags: []
        )
        let emptyFiveHour = menuBarSnapshot(
            label: "empty-five-hour@example.com",
            state: .ready,
            fiveHourRemainingPercent: 0,
            sevenDayRemainingPercent: 80,
            sortOrder: 7,
            tags: []
        )
        let emptySevenDay = menuBarSnapshot(
            label: "empty-seven-day@example.com",
            state: .ready,
            fiveHourRemainingPercent: 80,
            sevenDayRemainingPercent: 0,
            sortOrder: 8,
            tags: []
        )
        let exactThirtyFive = menuBarSnapshot(
            label: "exact-thirty-five@example.com",
            state: .ready,
            fiveHourRemainingPercent: 82,
            sevenDayRemainingPercent: 35,
            sortOrder: 9,
            tags: []
        )
        let lowFiveHour = menuBarSnapshot(
            label: "low-five-hour@example.com",
            state: .ready,
            fiveHourRemainingPercent: 9,
            sevenDayRemainingPercent: 80,
            sortOrder: 10,
            tags: []
        )
        let lowSevenDay = menuBarSnapshot(
            label: "low-seven-day@example.com",
            state: .ready,
            fiveHourRemainingPercent: 80,
            sevenDayRemainingPercent: 9,
            sortOrder: 11,
            tags: []
        )
        let exactTen = menuBarSnapshot(
            label: "exact-ten@example.com",
            state: .ready,
            fiveHourRemainingPercent: 10,
            sevenDayRemainingPercent: 10,
            sortOrder: 12,
            tags: []
        )
        let rows = [
            active,
            pending,
            mixed,
            untagged,
            fullActive,
            fullPending,
            secondaryFullOnly,
            emptyFiveHour,
            emptySevenDay,
            exactThirtyFive,
            lowFiveHour,
            lowSevenDay,
            exactTen,
        ]

        #expect(ProfileFilter().apply(to: rows).map(\.id) == rows.map(\.id))
        #expect(
            ProfileFilter([.active, .needAction]).apply(to: rows).map(\.id)
                == [active.id, mixed.id, fullActive.id]
        )
        #expect(
            ProfileFilter([.pending]).apply(to: rows).map(\.id)
                == [pending.id, mixed.id, fullPending.id]
        )
        #expect(
            ProfileFilter(limit: .usable).apply(to: rows).map(\.id)
                == [
                    active.id,
                    untagged.id,
                    fullActive.id,
                    fullPending.id,
                    secondaryFullOnly.id,
                    exactThirtyFive.id,
                    exactTen.id,
                ]
        )
        #expect(
            ProfileFilter(limit: .aboveThirtyFive).apply(to: rows).map(\.id)
                == [active.id, fullActive.id, fullPending.id, secondaryFullOnly.id]
        )
        #expect(
            ProfileFilter(limit: .fullFiveHour).apply(to: rows).map(\.id)
                == [fullActive.id, fullPending.id]
        )
        let limitCounts = ProfileLimitCounts(snapshots: rows)
        #expect(limitCounts.usable == 7)
        #expect(limitCounts.aboveThirtyFive == 4)
        #expect(limitCounts.fullFiveHour == 2)
        #expect(
            ProfileFilter(
                [.active],
                limit: .aboveThirtyFive
            ).apply(to: rows).map(\.id) == [active.id, fullActive.id]
        )

        var mutableFilter = ProfileFilter()
        mutableFilter.toggle(.usable)
        #expect(mutableFilter.isEmpty == false)
        #expect(mutableFilter.selectedLimit == .usable)
        mutableFilter.toggle(.aboveThirtyFive)
        #expect(mutableFilter.selectedLimit == .aboveThirtyFive)
        mutableFilter.toggle(.aboveThirtyFive)
        #expect(mutableFilter.isEmpty)
        mutableFilter.toggle(.fullFiveHour)
        mutableFilter.clear()
        #expect(mutableFilter.isEmpty)
        #expect(mutableFilter.selectedLimit == .any)
    }

    @Test
    func statusBarTextUsesPreferredReadyProfileBeforeUrgentFallback() {
        let controller = PlusProfileController(dataService: StubPlusProfileDataService(refreshResults: [:]), autoStart: false)
        let urgent = menuBarSnapshot(
            label: "urgent@example.com",
            state: .ready,
            fiveHourRemainingPercent: 12,
            sevenDayRemainingPercent: 38,
            sortOrder: 0
        )
        let preferred = menuBarSnapshot(
            label: "putrigildarahimah13@gmail.com",
            state: .ready,
            fiveHourRemainingPercent: 74,
            sevenDayRemainingPercent: 42,
            sortOrder: 1
        )
        controller.profiles = [urgent, preferred]

        #expect(controller.preferredStatusProfile(preferredProfileID: preferred.id)?.id == preferred.id)
        let content = controller.statusBarContent(
            preferredProfileID: preferred.id,
            referenceDate: Date(timeIntervalSince1970: 1_776_000_000)
        )
        #expect(content.profileLabel == "putrig**ah13@gma")
        #expect(content.fiveHourText == "74%")
        #expect(content.sevenDayText == "42%")
        #expect(content.plainText == "putrig**ah13@gma 5H 74% 7D 42%")
        #expect(content.accessibilityText == "putrig**ah13@gma, 5 hour 74%, 7 day 42%")
        #expect(
            controller.statusBarText(
                preferredProfileID: preferred.id,
                referenceDate: Date(timeIntervalSince1970: 1_776_000_000)
            ) == "putrig**ah13@gma 5H 74% 7D 42%"
        )
    }

    @Test(arguments: [
        ("alphaaccount@outlook.com", "alphaa**ount@out"),
        ("alphaaccount@icloud.com", "alphaa**ount@icl"),
        ("alphaaccount@hotmail.com", "alphaa**ount@hot"),
        ("alphaaccount@gmail.com", "alphaa**ount@gma"),
    ])
    func statusBarTextUsesOnlyThreeDomainCharactersForEmails(label: String, expectedLabel: String) {
        let controller = PlusProfileController(dataService: StubPlusProfileDataService(refreshResults: [:]), autoStart: false)
        let profile = menuBarSnapshot(
            label: label,
            state: .ready,
            fiveHourRemainingPercent: 83,
            sevenDayRemainingPercent: 72,
            sortOrder: 0
        )
        controller.profiles = [profile]

        let content = controller.statusBarContent(
            preferredProfileID: profile.id,
            referenceDate: Date(timeIntervalSince1970: 1_776_000_000)
        )

        #expect(content.profileLabel == expectedLabel)
    }

    @Test
    func statusBarSymbolUsesRunningFigureForHealthyReadyState() {
        let controller = PlusProfileController(dataService: StubPlusProfileDataService(refreshResults: [:]), autoStart: false)
        controller.dashboardStatus = .ready
        let profile = menuBarSnapshot(
            label: "runner@example.com",
            state: .ready,
            fiveHourRemainingPercent: 83,
            sevenDayRemainingPercent: 72,
            sortOrder: 0
        )
        controller.profiles = [profile]

        #expect(controller.statusBarSymbolName == "figure.run")
    }

    @Test
    func preferredStatusProfileFallsBackWhenPreferredProfileIsMissingOrNotReady() {
        let controller = PlusProfileController(dataService: StubPlusProfileDataService(refreshResults: [:]), autoStart: false)
        let urgent = menuBarSnapshot(
            label: "UrgentProfile",
            state: .ready,
            fiveHourRemainingPercent: 18,
            sevenDayRemainingPercent: 51,
            sortOrder: 0
        )
        let needsLogin = menuBarSnapshot(
            label: "repair@example.com",
            state: .needsLogin,
            fiveHourRemainingPercent: nil,
            sevenDayRemainingPercent: nil,
            sortOrder: 1
        )
        controller.profiles = [urgent, needsLogin]

        #expect(controller.preferredStatusProfile(preferredProfileID: needsLogin.id)?.id == urgent.id)
        #expect(controller.preferredStatusProfile(preferredProfileID: UUID())?.id == urgent.id)
        #expect(
            controller.statusBarText(
                preferredProfileID: needsLogin.id,
                referenceDate: Date(timeIntervalSince1970: 1_776_000_000)
            ) == "UrgentP 5H 18% 7D 51%"
        )
    }

    @Test
    func statusBarTextUsesSevenCharacterNonEmailPrefixWithoutEllipsis() {
        let controller = PlusProfileController(dataService: StubPlusProfileDataService(refreshResults: [:]), autoStart: false)
        let profile = menuBarSnapshot(
            label: "LongLabelProfile",
            state: .ready,
            fiveHourRemainingPercent: 83,
            sevenDayRemainingPercent: nil,
            sortOrder: 0
        )
        controller.profiles = [profile]

        #expect(
            controller.statusBarText(
                preferredProfileID: profile.id,
                referenceDate: Date(timeIntervalSince1970: 1_776_000_000)
            ) == "LongLab 5H 83% 7D —"
        )
    }
}

@MainActor
private final class StubPlusProfileDataService: PlusProfileDataServing {
    private let refreshResults: [UUID: Result<PlusProfileRefreshResult, ChatGPTAPIError>]
    private let syncResults: [UUID: Result<ChatGPTAuthContext, ChatGPTAPIError>]
    private let chromeSignInFinishResults: [UUID: Bool]
    private(set) var openedChromeAccountPageProfileIDs: [UUID] = []
    private(set) var openedChromeProfileIDs: [UUID] = []
    private(set) var openedPasskeySetupProfileIDs: [UUID] = []
    private(set) var syncedChromeProfileIDs: [UUID] = []
    private(set) var waitedForChromeProfileIDs: [UUID] = []
    private(set) var closedChromeProfileIDs: [UUID] = []
    private(set) var clearedProfileIDs: [UUID] = []
    private(set) var removedProfileIDs: [UUID] = []

    init(
        refreshResults: [UUID: Result<PlusProfileRefreshResult, ChatGPTAPIError>],
        syncResults: [UUID: Result<ChatGPTAuthContext, ChatGPTAPIError>] = [:],
        chromeSignInFinishResults: [UUID: Bool] = [:]
    ) {
        self.refreshResults = refreshResults
        self.syncResults = syncResults
        self.chromeSignInFinishResults = chromeSignInFinishResults
    }

    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        let result = try #require(refreshResults[profile.id])
        return try result.get()
    }

    func openChromeSignIn(for profile: PlusProfile) async throws {
        openedChromeProfileIDs.append(profile.id)
    }

    func openChromeAccountPage(for profile: PlusProfile) async throws {
        openedChromeAccountPageProfileIDs.append(profile.id)
    }

    func openChromePasskeySetup(for profile: PlusProfile) async throws {
        openedPasskeySetupProfileIDs.append(profile.id)
    }

    func syncChromeSession(for profile: PlusProfile) async throws {
        syncedChromeProfileIDs.append(profile.id)
        if let result = syncResults[profile.id] {
            _ = try result.get()
        }
    }

    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool {
        waitedForChromeProfileIDs.append(profile.id)
        return chromeSignInFinishResults[profile.id] ?? false
    }

    func closeChromeSignIn(for profile: PlusProfile) async {
        closedChromeProfileIDs.append(profile.id)
    }

    func clearSession(for profile: PlusProfile) async throws {
        clearedProfileIDs.append(profile.id)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        removedProfileIDs.append(profile.id)
    }

}

private actor ConcurrencyRecorder {
    private var current = 0
    private(set) var maxConcurrent = 0

    func begin() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func end() {
        current = max(0, current - 1)
    }
}

@MainActor
private final class ConcurrencyRecordingProfileDataService: PlusProfileDataServing {
    private let delayNanoseconds: UInt64
    private let recorder = ConcurrencyRecorder()

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    var maxConcurrent: Int {
        get async {
            await recorder.maxConcurrent
        }
    }

    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        await recorder.begin()
        defer {
            Task {
                await recorder.end()
            }
        }

        try await Task.sleep(nanoseconds: delayNanoseconds)
        return PlusProfileRefreshResult(
            usage: makeUsage(
                accountID: "acct_\(profile.sortOrder)",
                primaryUsedPercent: 20 + profile.sortOrder,
                secondaryUsedPercent: 30 + profile.sortOrder
            ),
            detectedNote: "Chatgpt Plus · \(profile.sortOrder)",
            expiryRefresh: .value(Date(timeIntervalSince1970: 1_779_097_600 + TimeInterval(profile.sortOrder)))
        )
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

private func makeUsage(
    accountID: String,
    primaryUsedPercent: Int,
    secondaryUsedPercent: Int
) -> PlusProfileUsage {
    PlusProfileUsage(
        accountID: accountID,
        planType: "chatgpt_plus",
        primaryWindow: WorkspaceLimitWindow(
            usedPercent: primaryUsedPercent,
            resetAt: Date(timeIntervalSince1970: 1_776_000_900)
        ),
        secondaryWindow: WorkspaceLimitWindow(
            usedPercent: secondaryUsedPercent,
            resetAt: Date(timeIntervalSince1970: 1_776_086_400)
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
    )
}

private func menuBarSnapshot(
    label: String,
    state: PlusProfileState,
    fiveHourRemainingPercent: Int?,
    sevenDayRemainingPercent: Int?,
    sortOrder: Int,
    tags: [PlusProfileTag] = []
) -> PlusProfileSnapshot {
    let profile = PlusProfile(
        id: UUID(),
        label: label,
        emailLink: nil,
        detectedNote: nil,
        tags: tags,
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
        lastRefreshAt: nil,
        lastKnownState: state.storedState
    )

    let usage = makeMenuBarUsage(
        accountID: "acct_\(sortOrder)",
        fiveHourRemainingPercent: fiveHourRemainingPercent,
        sevenDayRemainingPercent: sevenDayRemainingPercent
    )

    return PlusProfileSnapshot(
        profile: profile,
        state: state,
        usage: usage,
        statusMessage: nil,
        isRefreshing: false
    )
}

private func makeMenuBarUsage(
    accountID: String,
    fiveHourRemainingPercent: Int?,
    sevenDayRemainingPercent: Int?
) -> PlusProfileUsage? {
    guard let fiveHourRemainingPercent else {
        return nil
    }

    let fiveHourWindow = WorkspaceLimitWindow(
        usedPercent: 100 - fiveHourRemainingPercent,
        resetAt: Date(timeIntervalSince1970: 1_776_000_900)
    )
    let sevenDayWindow = sevenDayRemainingPercent.map {
        WorkspaceLimitWindow(
            usedPercent: 100 - $0,
            resetAt: Date(timeIntervalSince1970: 1_776_086_400)
        )
    }

    return PlusProfileUsage(
        accountID: accountID,
        planType: "chatgpt_plus",
        primaryWindow: fiveHourWindow,
        secondaryWindow: sevenDayWindow,
        fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
    )
}

private func sampleProfile(label: String, sortOrder: Int, emailLink: String? = nil) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: label,
        emailLink: emailLink,
        detectedNote: nil,
        tags: [],
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
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
