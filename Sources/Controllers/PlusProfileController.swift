import Foundation
import Observation

struct MenuBarStatusContent: Equatable, Sendable {
    let profileLabel: String
    let fiveHourText: String
    let sevenDayText: String
    let showsUsageSummary: Bool

    var plainText: String {
        guard showsUsageSummary else {
            return profileLabel
        }

        return "\(profileLabel) 5H \(fiveHourText) 7D \(sevenDayText)"
    }

    var accessibilityText: String {
        guard showsUsageSummary else {
            return profileLabel
        }

        return "\(profileLabel), 5 hour \(fiveHourText), 7 day \(sevenDayText)"
    }

    static func usage(
        profileLabel: String,
        fiveHourText: String,
        sevenDayText: String
    ) -> MenuBarStatusContent {
        MenuBarStatusContent(
            profileLabel: profileLabel,
            fiveHourText: fiveHourText,
            sevenDayText: sevenDayText,
            showsUsageSummary: true
        )
    }

    static func text(_ text: String) -> MenuBarStatusContent {
        MenuBarStatusContent(
            profileLabel: text,
            fiveHourText: "",
            sevenDayText: "",
            showsUsageSummary: false
        )
    }
}

private struct ProfileStateCounts {
    var ready = 0
    var needsLogin = 0
    var failed = 0

    var hasKnownState: Bool {
        ready > 0 || needsLogin > 0 || failed > 0
    }
}

struct OpenChamberActionStatus: Equatable {
    let profileID: UUID
    let message: String
    let tone: CodexStatusTone
}

@Observable
@MainActor
final class PlusProfileController {
    static let touchIDPasskeyHelpMessage = "Touch ID works when the OpenAI passkey is in Apple Passwords or synced into this Chrome profile. Touch ID help opens the full Chrome setup; normal sign-in stays lightweight."

    var profiles: [PlusProfileSnapshot] = []
    var selectedProfileID: UUID?
    var statusMessage: String?
    var isRefreshing = false
    private(set) var isTransferring = false
    @ObservationIgnored private var activeDataOperations = 0
    var dashboardStatus: PlusDashboardStatus = .empty
    var chromeSignInProfileIDs: Set<UUID> = []
    var switchingProfileIDs: Set<UUID> = []
    var openCodeSwitchingProfileIDs: Set<UUID> = []
    var openChamberActionStatus: OpenChamberActionStatus?
    var desktopSignInStatus: OpenChamberActionStatus?
    var openChamberSyncResult: OpenChamberSyncResult? { syncScheduler.result }
    var openChamberSyncMessage: String? { syncScheduler.message }
    var isOpenChamberSyncing: Bool { syncScheduler.isSyncing }
    @ObservationIgnored private let syncScheduler: OpenChamberSyncScheduler
    @ObservationIgnored private var removingProfileIDs: Set<UUID> = []

    @ObservationIgnored private let catalogStore: ProfileCatalogStore
    @ObservationIgnored private let dataService: PlusProfileDataServing
    @ObservationIgnored private let accountSwitchService: any CodexAccountSwitchServing
    @ObservationIgnored private let openCodeAuthService: any OpenCodeOpenAIAuthServing
    @ObservationIgnored private let autoRefreshIntervalNanoseconds: UInt64
    @ObservationIgnored private let maxConcurrentProfileRefreshes: Int
    @ObservationIgnored private let autoRefreshSleep: @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    init(
        catalogStore: ProfileCatalogStore = ProfileCatalogStore(),
        dataService: PlusProfileDataServing = PlusProfileDataService(),
        accountSwitchService: any CodexAccountSwitchServing = CodexAccountSwitchService(),
        openCodeAuthService: any OpenCodeOpenAIAuthServing = OpenCodeOpenAIAuthService(),
        syncService: any OpenChamberSyncServing = OpenChamberSyncService(),
        syncDefaults: UserDefaults = .standard,
        autoRefreshInterval: TimeInterval = 300,
        maxConcurrentProfileRefreshes: Int = 3,
        autoRefreshSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(for: .nanoseconds(Int64(clamping: $0)))
        },
        autoStart: Bool = true
    ) {
        self.catalogStore = catalogStore
        self.dataService = dataService
        self.accountSwitchService = accountSwitchService
        self.openCodeAuthService = openCodeAuthService
        self.syncScheduler = OpenChamberSyncScheduler(service: syncService, defaults: syncDefaults)
        self.autoRefreshIntervalNanoseconds = UInt64(autoRefreshInterval * 1_000_000_000)
        self.maxConcurrentProfileRefreshes = max(1, maxConcurrentProfileRefreshes)
        self.autoRefreshSleep = autoRefreshSleep
        loadStoredProfiles()

        if autoStart {
            startBackgroundTasks()
        }
    }

    /// Starts the refresh loops after app startup work (such as the Chrome
    /// storage migration) has completed.  Keeping this separate from `init`
    /// prevents a first-run migration from racing a Claude cookie restore.
    func startBackgroundTasks() {
        guard !isTransferring else { return }
        guard bootstrapTask == nil, autoRefreshTask == nil else {
            return
        }

        bootstrapTask = Task { [weak self] in
            await self?.refreshAll()
        }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let sleep = self?.autoRefreshSleep, let interval = self?.autoRefreshIntervalNanoseconds else { return }
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
        syncScheduler.start()
    }

    func pauseForBackup() async throws {
        guard !isTransferring else { throw BackupError.busy }
        isTransferring = true
        bootstrapTask?.cancel(); autoRefreshTask?.cancel()
        await syncScheduler.pauseForManualOperation()
        // Closing the app-owned sign-in session releases its return-to-app waiter.
        // Existing writes drain; new mutations are refused by the transfer gate.
        while activeDataOperations > 0 || isRefreshing {
            for profile in profiles { await dataService.closeChromeSignIn(for: profile.profile) }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        for profile in profiles { await dataService.closeChromeSignIn(for: profile.profile) }
        chromeSignInProfileIDs.removeAll()
        await bootstrapTask?.value
        await autoRefreshTask?.value
        bootstrapTask = nil; autoRefreshTask = nil
        // An already-running manual sign-in may have resumed sync in its defer.
        await syncScheduler.pauseForManualOperation()
        try Task.checkCancellation()
    }

    func resumeAfterBackup(reload: Bool, startTasks: Bool = true) {
        if reload {
            statusMessage = nil
            loadStoredProfiles()
        }
        isTransferring = false
        bootstrapTask = nil; autoRefreshTask = nil
        syncScheduler.resumeAfterManualOperation()
        if startTasks { startBackgroundTasks() }
    }

    deinit {
        bootstrapTask?.cancel()
        autoRefreshTask?.cancel()
    }

    var selectedProfile: PlusProfileSnapshot? {
        guard let selectedProfileID else {
            return profiles.first
        }

        return profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
    }

    var statusBarSymbolName: String {
        if let urgent = mostUrgentHealthyProfile(),
           let remaining = urgent.usage?.fiveHourRemainingPercent,
           remaining <= 20 {
            return "exclamationmark.triangle.fill"
        }

        return dashboardStatus.symbolName
    }

    func preferredStatusProfile(preferredProfileID: UUID?) -> PlusProfileSnapshot? {
        if let preferredProfileID,
           let preferred = profiles.first(where: { $0.id == preferredProfileID }),
           preferred.state == .ready,
           preferred.usage != nil {
            return preferred
        }

        return mostUrgentHealthyProfile()
    }

    func statusBarText(
        preferredProfileID: UUID?,
        referenceDate: Date = .now
    ) -> String {
        statusBarContent(
            preferredProfileID: preferredProfileID,
            referenceDate: referenceDate
        ).plainText
    }

    func statusBarContent(referenceDate: Date = .now) -> MenuBarStatusContent {
        statusBarContent(preferredProfileID: nil, referenceDate: referenceDate)
    }

    func statusBarContent(
        preferredProfileID: UUID?,
        referenceDate: Date = .now
    ) -> MenuBarStatusContent {
        if let preferred = preferredStatusProfile(preferredProfileID: preferredProfileID) {
            let label = compactStatusLabel(for: preferred.profile.displayLabel)
            return .usage(
                profileLabel: label,
                fiveHourText: preferred.fiveHourText,
                sevenDayText: preferred.sevenDayText
            )
        }

        if isRefreshing {
            return .text(profiles.isEmpty ? "Checking…" : "Refreshing…")
        }

        let stateCounts = profileStateCounts
        switch dashboardStatus {
        case .empty:
            return .text("Add profile")
        case .needsLogin:
            return .text("Login needed")
        case .failed:
            return .text("Check profiles")
        case .mixedAttention:
            return .text("\(stateCounts.ready)/\(profiles.count) ready")
        case .refreshing:
            return .text("Refreshing…")
        case .ready:
            if let refreshedAt = profiles.compactMap(\.lastRefreshAt).max(),
               let updated = DisplayFormatter.updatedText(refreshedAt, referenceDate: referenceDate) {
                return .text(updated.replacingOccurrences(of: "Updated ", with: ""))
            }

            return .text("\(stateCounts.ready) ready")
        }
    }

    func addProfile(
        label: String? = nil,
        provider: ProfileProvider = .codex
    ) {
        guard !isTransferring else { return }
        let nextIndex = profiles.count + 1
        let newProfile = PlusProfile(
            id: UUID(),
            provider: provider,
            label: label ?? "Account \(nextIndex)",
            emailLink: nil,
            detectedNote: nil,
            webDataStoreID: UUID(),
            sortOrder: profiles.count,
            createdAt: .now,
            lastRefreshAt: nil,
            lastKnownState: .unknown
        )

        profiles.append(
            PlusProfileSnapshot(
                profile: newProfile,
                state: .idle,
                usage: nil,
                statusMessage: "Open Chrome to sign in to \(provider.displayName).",
                isRefreshing: false
            )
        )
        selectedProfileID = newProfile.id
        persistProfiles()
        updateDashboardStatus()
    }

    @discardableResult
    func importProfiles(from rawText: String) -> BulkProfileImportPreview {
        let preview = BulkProfileImporter.preview(from: rawText)
        guard !isTransferring else { return preview }
        guard preview.canSubmit else {
            statusMessage = preview.issueSummary ?? "Paste at least one profile row."
            updateDashboardStatus()
            return preview
        }

        let previousProfiles = profiles
        let previousSelectedProfileID = selectedProfileID
        let createdAt = Date.now
        let startSortOrder = profiles.count
        let importedProfiles = preview.entries.enumerated().map { offset, entry in
            PlusProfile(
                id: UUID(),
                label: entry.email,
                emailLink: BulkProfileImporter.twoFactorLiveLink,
                detectedNote: nil,
                password: entry.password,
                twoFactorCode: entry.twoFactorCode,
                webDataStoreID: UUID(),
                sortOrder: startSortOrder + offset,
                createdAt: createdAt.addingTimeInterval(Double(offset) / 1_000),
                lastRefreshAt: nil,
                lastKnownState: .unknown
            )
        }

        profiles.append(contentsOf: importedProfiles.map { profile in
            PlusProfileSnapshot(
                profile: profile,
                state: .idle,
                usage: nil,
                statusMessage: "Open Chrome to sign in with this account.",
                isRefreshing: false
            )
        })
        selectedProfileID = importedProfiles.first?.id

        guard persistProfiles() else {
            profiles = previousProfiles
            selectedProfileID = previousSelectedProfileID
            updateDashboardStatus()
            return preview
        }

        statusMessage = importedProfiles.count == 1
            ? "Imported 1 profile."
            : "Imported \(importedProfiles.count) profiles."
        updateDashboardStatus()
        return preview
    }

    func selectProfile(id: UUID?) {
        selectedProfileID = id ?? profiles.first?.id
    }

    @discardableResult
    func setProvider(
        _ provider: ProfileProvider,
        for profileID: UUID
    ) async -> Bool {
        guard !isTransferring else { return false }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard let index = indexOfProfile(profileID) else {
            return false
        }

        let snapshot = profiles[index]
        guard snapshot.profile.provider != provider else {
            return true
        }

        let previousProfiles = profiles
        let previousProfile = snapshot.profile
        var updatedProfile = previousProfile
        updatedProfile.provider = provider
        updatedProfile.detectedNote = nil
        updatedProfile.expiresAt = nil
        updatedProfile.lastRefreshAt = nil
        updatedProfile.lastKnownState = .needsLogin

        profiles[index] = snapshot.updating(
            profile: updatedProfile,
            state: .needsLogin,
            usage: .some(nil),
            statusMessage: .some("Open Chrome to sign in to \(provider.displayName)."),
            isRefreshing: false
        )

        guard persistProfiles() else {
            profiles = previousProfiles
            return false
        }

        chromeSignInProfileIDs.remove(profileID)
        await dataService.closeChromeSignIn(for: previousProfile)
        updateDashboardStatus()
        return true
    }

    @discardableResult
    func updateDetails(for profileID: UUID, draft: PlusProfileDetailsDraft) -> Bool {
        guard !isTransferring else { return false }
        guard let index = indexOfProfile(profileID) else {
            return false
        }

        let previousProfiles = profiles
        let snapshot = profiles[index]
        profiles[index] = snapshot.updating(profile: draft.applying(to: snapshot.profile))

        guard persistProfiles() else {
            profiles = previousProfiles
            return false
        }

        return true
    }

    func setTags(_ tags: [PlusProfileTag], for profileID: UUID) {
        guard !isTransferring else { return }
        guard let index = indexOfProfile(profileID) else { return }
        var updatedProfile = profiles[index].profile
        updatedProfile.tags = PlusProfile.normalizedTags(tags)
        profiles[index] = profiles[index].updating(profile: updatedProfile)
        persistProfiles()
    }

    func toggleTag(_ tag: PlusProfileTag, for profileID: UUID) {
        guard !isTransferring else { return }
        guard let index = indexOfProfile(profileID) else { return }
        var updatedTags = profiles[index].profile.normalizedTags

        if updatedTags.contains(tag) {
            updatedTags.removeAll { $0 == tag }
        } else {
            updatedTags.append(tag)
        }

        setTags(updatedTags, for: profileID)
    }

    func moveSelectedProfileUp() {
        guard !isTransferring else { return }
        guard let selectedProfileID,
              let index = indexOfProfile(selectedProfileID),
              index > 0 else { return }

        profiles.swapAt(index, index - 1)
        persistProfiles()
    }

    func moveSelectedProfileDown() {
        guard !isTransferring else { return }
        guard let selectedProfileID,
              let index = indexOfProfile(selectedProfileID),
              index < profiles.count - 1 else { return }

        profiles.swapAt(index, index + 1)
        persistProfiles()
    }

    func refreshAll() async {
        guard !isTransferring else { return }
        guard isRefreshing == false else { return }
        guard profiles.isEmpty == false else {
            statusMessage = "Add a profile, then sign in one by one."
            updateDashboardStatus()
            return
        }

        isRefreshing = true
        statusMessage = nil
        updateDashboardStatus()

        for profile in profiles {
            setRefreshingState(for: profile.id, isRefreshing: true)
        }

        let profileIDs = profiles.map(\.id)
        for batch in profileIDs.chunked(into: maxConcurrentProfileRefreshes) {
            let tasks = batch.map { profileID in
                Task { @MainActor [weak self] in
                    await self?.refreshProfile(id: profileID, isBackgroundBatch: true)
                }
            }

            for task in tasks {
                await task.value
            }
        }

        isRefreshing = false
        statusMessage = makeGlobalStatusMessage()
        updateDashboardStatus()
    }

    func refreshProfile(id profileID: UUID) async {
        await refreshProfile(id: profileID, isBackgroundBatch: false)
    }

    func switchAndOpen(profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard switchingProfileIDs.isEmpty, let index = indexOfProfile(profileID),
              profiles[index].profile.provider == .codex else { return }
        let profile = profiles[index].profile
        switchingProfileIDs.insert(profileID)
        desktopSignInStatus = .init(profileID: profileID, message: "Switching and reopening ChatGPT / Codex…", tone: .info)
        defer { switchingProfileIDs.remove(profileID) }
        do {
            try await accountSwitchService.switchAndOpen(profile: profile)
            desktopSignInStatus = .init(profileID: profileID, message: "Sign-in verified. Desktop app reopened.", tone: .success)
            statusMessage = "Switched to \(profile.displayLabel) and reopened ChatGPT / Codex."
        } catch {
            let message = desktopSignInMessage(error)
            desktopSignInStatus = .init(profileID: profileID, message: message, tone: .critical)
            statusMessage = message
        }
    }

    func saveDesktopSignIn(profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard switchingProfileIDs.isEmpty, let index = indexOfProfile(profileID),
              profiles[index].profile.provider == .codex else { return }
        let profile = profiles[index].profile
        switchingProfileIDs.insert(profileID)
        desktopSignInStatus = .init(profileID: profileID, message: "Saving the current desktop sign-in…", tone: .info)
        defer { switchingProfileIDs.remove(profileID) }
        do {
            let identity = try await accountSwitchService.saveCurrent(for: profile)
            guard let currentIndex = indexOfProfile(profileID) else {
                throw CodexSignInError.concurrentChange
            }
            let previous = profiles[currentIndex]
            guard previous.profile.provider == profile.provider,
                  previous.profile.label == profile.label,
                  previous.profile.codexAccountKey == profile.codexAccountKey,
                  previous.profile.codexSignIn == profile.codexSignIn,
                  previous.profile.openCodeOpenAIAccount == profile.openCodeOpenAIAccount else {
                throw CodexSignInError.concurrentChange
            }
            var updated = previous.profile
            updated.codexSignIn = identity
            profiles[currentIndex] = previous.updating(profile: updated)
            guard persistProfiles() else {
                profiles[currentIndex] = previous
                throw CodexSignInError.storageFailed
            }
            desktopSignInStatus = .init(profileID: profileID, message: "Desktop sign-in saved.", tone: .success)
        } catch {
            desktopSignInStatus = .init(profileID: profileID, message: desktopSignInMessage(error), tone: .critical)
        }
    }

    private func desktopSignInMessage(_ error: any Error) -> String {
        if let error = error as? CodexSignInError { return error.localizedDescription }
        if let error = error as? CodexSignInSwitchError { return error.localizedDescription }
        if error is CancellationError { return "The desktop sign-in action was cancelled." }
        return "The desktop sign-in could not be saved or switched. Try again."
    }

    func saveOpenChamberAuth(profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard openCodeSwitchingProfileIDs.isEmpty, let index = indexOfProfile(profileID),
              profiles[index].profile.provider == .codex else { return }
        let profile = profiles[index].profile
        openCodeSwitchingProfileIDs.insert(profileID)
        openChamberActionStatus = .init(profileID: profileID, message: "Checking the local OpenChamber sign-in…", tone: .info)
        defer { openCodeSwitchingProfileIDs.remove(profileID); syncScheduler.resumeAfterManualOperation() }
        await syncScheduler.pauseForManualOperation()
        do {
            let identity = try await openCodeAuthService.saveCurrent(for: profile)
            // Profile edits/removal can happen while the local backend is checked.
            guard let currentIndex = indexOfProfile(profileID),
                  profiles[currentIndex].profile.provider == profile.provider,
                  profiles[currentIndex].profile.label == profile.label,
                  profiles[currentIndex].profile.codexSignIn == profile.codexSignIn,
                  profiles[currentIndex].profile.codexAccountKey == profile.codexAccountKey,
                  profiles[currentIndex].profile.openCodeOpenAIAccount == profile.openCodeOpenAIAccount else {
                throw OpenCodeOpenAIAuthError.changedWhileReading
            }
            let previous = profiles[currentIndex]
            var updated = previous.profile
            updated.openCodeOpenAIAccount = identity
            profiles[currentIndex] = previous.updating(profile: updated)
            guard persistProfiles() else {
                profiles[currentIndex] = previous
                throw OpenCodeOpenAIAuthError.writeFailed
            }
            openChamberActionStatus = .init(profileID: profileID, message: "OpenChamber sign-in saved.", tone: .success)
        } catch {
            openChamberActionStatus = .init(profileID: profileID, message: error.localizedDescription, tone: .critical)
        }
    }

    func switchOpenChamberAuth(profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard openCodeSwitchingProfileIDs.isEmpty, let index = indexOfProfile(profileID),
              profiles[index].profile.provider == .codex else { return }
        openCodeSwitchingProfileIDs.insert(profileID)
        let profile = profiles[index].profile
        openChamberActionStatus = .init(profileID: profileID, message: "Switching and verifying OpenChamber OpenAI…", tone: .info)
        defer { openCodeSwitchingProfileIDs.remove(profileID); syncScheduler.resumeAfterManualOperation() }
        await syncScheduler.pauseForManualOperation()
        do {
            try await openCodeAuthService.switchTo(profile: profile)
            openChamberActionStatus = .init(profileID: profileID,
                message: "OpenChamber OpenAI switched and verified. Refresh OpenChamber’s Usage panel if it still shows an older result.", tone: .success)
        } catch {
            openChamberActionStatus = .init(profileID: profileID, message: error.localizedDescription, tone: .critical)
        }
    }

    func clearSession(for profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]

        do {
            try await dataService.clearSession(for: snapshot.profile)
            var updatedProfile = snapshot.profile
            updatedProfile.lastKnownState = .needsLogin
            profiles[index] = snapshot.updating(
                profile: updatedProfile,
                state: .needsLogin,
                usage: .some(nil),
                statusMessage: .some(
                    "Open Chrome to sign in to \(snapshot.profile.provider.displayName) again."
                ),
                isRefreshing: false
            )
            chromeSignInProfileIDs.remove(profileID)
            persistProfiles()
            updateDashboardStatus()
        } catch {
            applyFailure(
                ChatGPTAPIError.map(error),
                to: profileID,
                preserveUsage: true
            )
        }
    }

    func removeProfile(id profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard !removingProfileIDs.contains(profileID), let index = indexOfProfile(profileID) else { return }
        removingProfileIDs.insert(profileID)
        defer { removingProfileIDs.remove(profileID) }
        let snapshot = profiles[index]

        do {
            try await dataService.removeProfileData(for: snapshot.profile)
            guard let currentIndex = indexOfProfile(profileID) else { return }
            let candidate = profiles.filter { $0.id != profileID }.enumerated().map { offset, snapshot in
                var profile = snapshot.profile; profile.sortOrder = offset
                return snapshot.updating(profile: profile)
            }
            do { try catalogStore.saveProfiles(candidate.map(\.profile)) }
            catch {
                syncScheduler.update(profiles: profiles.map(\.profile), trusted: false)
                statusMessage = "The profile list could not be saved locally."
                return
            }
            profiles = candidate
            syncScheduler.update(profiles: candidate.map(\.profile), trusted: true)
            chromeSignInProfileIDs.remove(profileID)

            if selectedProfileID == profileID {
                selectedProfileID = profiles.indices.contains(currentIndex)
                    ? profiles[currentIndex].id
                    : profiles.last?.id
            }

            statusMessage = profiles.isEmpty ? "All profiles were removed." : nil
            updateDashboardStatus()
        } catch {
            applyFailure(
                ChatGPTAPIError.map(error),
                to: profileID,
                preserveUsage: true
            )
        }
    }

    func isChromeSignInOpen(for profileID: UUID) -> Bool {
        chromeSignInProfileIDs.contains(profileID)
    }

    func openChrome(for profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard var index = indexOfProfile(profileID) else { return }
        var snapshot = profiles[index]

        if snapshot.profile.provider == .claude, snapshot.state != .ready {
            await refreshProfile(id: profileID)

            guard let refreshedIndex = indexOfProfile(profileID) else { return }
            index = refreshedIndex
            snapshot = profiles[index]
        }

        if snapshot.state == .ready, snapshot.usage != nil {
            do {
                try await dataService.openChromeAccountPage(for: snapshot.profile)
            } catch {
                applyFailure(
                    ChatGPTAPIError.map(error),
                    to: profileID,
                    preserveUsage: true
                )
            }
            return
        }

        do {
            try await dataService.openChromeSignIn(for: snapshot.profile)
            chromeSignInProfileIDs.insert(profileID)
            if let refreshedIndex = indexOfProfile(profileID) {
                profiles[refreshedIndex] = profiles[refreshedIndex].updating(
                    statusMessage: .some(
                        "Sign in, then return here. Usage updates automatically."
                    ),
                    isRefreshing: false
                )
            }
            updateDashboardStatus()

            let didFinish = await dataService.waitForChromeSignInToFinish(
                for: snapshot.profile
            )
            guard didFinish, chromeSignInProfileIDs.contains(profileID) else {
                return
            }

            await syncChromeSession(for: profileID)
        } catch {
            applyFailure(
                ChatGPTAPIError.map(error),
                to: profileID,
                preserveUsage: true
            )
        }
    }

    func openChromePasskeySetup(for profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]

        do {
            try await dataService.openChromePasskeySetup(for: snapshot.profile)
            chromeSignInProfileIDs.insert(profileID)
            if let refreshedIndex = indexOfProfile(profileID) {
                profiles[refreshedIndex] = profiles[refreshedIndex].updating(
                    statusMessage: .some(Self.touchIDPasskeyHelpMessage),
                    isRefreshing: false
                )
            }
            updateDashboardStatus()
        } catch {
            applyFailure(
                ChatGPTAPIError.map(error),
                to: profileID,
                preserveUsage: true
            )
        }
    }

    func syncChromeSession(for profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]
        setRefreshingState(for: profileID, isRefreshing: true)

        do {
            try await dataService.syncChromeSession(for: snapshot.profile)
            chromeSignInProfileIDs.remove(profileID)
            await refreshProfile(id: profileID)
        } catch {
            let mappedError = ChatGPTAPIError.map(error)
            if mappedError == .unauthorized {
                markChromeSignInNeedsMoreTime(profileID: profileID)
                return
            }

            applyFailure(mappedError, to: profileID, preserveUsage: true)
        }
    }

    func closeChromeSignIn(for profileID: UUID) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]
        await dataService.closeChromeSignIn(for: snapshot.profile)
        chromeSignInProfileIDs.remove(profileID)

        if let refreshedIndex = indexOfProfile(profileID) {
            profiles[refreshedIndex] = profiles[refreshedIndex].updating(
                statusMessage: .some("Chrome sign-in was cancelled."),
                isRefreshing: false
            )
        }
        updateDashboardStatus()
    }

    private func refreshProfile(id profileID: UUID, isBackgroundBatch: Bool) async {
        guard !isTransferring else { return }
        activeDataOperations += 1
        defer { activeDataOperations -= 1 }
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]
        setRefreshingState(for: profileID, isRefreshing: true)

        do {
            let result = try await dataService.refreshProfile(snapshot.profile)
            guard let currentIndex = indexOfProfile(profileID) else { return }
            let current = profiles[currentIndex]
            var updatedProfile = current.profile
            updatedProfile.detectedNote = result.detectedNote
            if case let .value(expiresAt) = result.expiryRefresh {
                updatedProfile.expiresAt = expiresAt
            }
            updatedProfile.lastRefreshAt = result.usage.fetchedAt
            updatedProfile.lastKnownState = .active

            profiles[currentIndex] = current.updating(
                profile: updatedProfile,
                state: .ready,
                usage: .some(result.usage),
                statusMessage: .some(nil),
                isRefreshing: false
            )
            persistProfiles()
        } catch {
            let mappedError = ChatGPTAPIError.map(error)
            let preserveUsage = mappedError != .unauthorized
            applyFailure(mappedError, to: profileID, preserveUsage: preserveUsage)
        }

        if isBackgroundBatch == false {
            statusMessage = makeGlobalStatusMessage()
            updateDashboardStatus()
        }
    }

    private func loadStoredProfiles() {
        let storedProfiles: [PlusProfile]
        var repairMessage: String?
        var trusted = false

        do {
            let loadResult = try catalogStore.loadProfilesWithReport()
            trusted = loadResult.sourceExists
            let pendingRestore = FileManager.default.fileExists(atPath: catalogStore.directory.appendingPathComponent(BackupService.receiptName).path)
            let migration = pendingRestore ? (loadResult.profiles, changed: false) : accountSwitchService.migrate(loadResult.profiles)
            storedProfiles = migration.0
            if migration.changed {
                do {
                    try catalogStore.saveProfiles(storedProfiles)
                    repairMessage = "Imported saved desktop sign-ins."
                } catch {
                    trusted = false
                    repairMessage = "Desktop sign-ins were imported, but the profile links could not be saved."
                }
            }

            if loadResult.removedDuplicateCount > 0 {
                do {
                    try catalogStore.saveProfiles(storedProfiles)
                    repairMessage = loadResult.removedDuplicateCount == 1
                        ? "Fixed 1 duplicate saved profile."
                        : "Fixed \(loadResult.removedDuplicateCount) duplicate saved profiles."
                } catch {
                    trusted = false
                    repairMessage = "A duplicate profile was hidden, but the saved list could not be repaired."
                }
            }
        } catch {
            storedProfiles = []
            statusMessage = "The saved profile list could not be read. Starting with an empty list."
        }

        profiles = storedProfiles.map { profile in
            PlusProfileSnapshot(
                profile: profile,
                state: initialState(for: profile),
                usage: nil,
                statusMessage: initialMessage(for: profile),
                isRefreshing: false
            )
        }
        selectedProfileID = profiles.first?.id
        syncScheduler.update(profiles: storedProfiles, trusted: trusted)
        statusMessage = repairMessage ?? statusMessage
        updateDashboardStatus()
    }

    func syncOpenChamberNow() async {
        guard !isTransferring else { return }
        await syncScheduler.syncNow()
    }

    private func initialState(for profile: PlusProfile) -> PlusProfileState {
        switch profile.lastKnownState {
        case .unknown, .active:
            return .idle
        case .needsLogin:
            return .needsLogin
        case .failed:
            return .failed
        }
    }

    private func initialMessage(for profile: PlusProfile) -> String? {
        switch profile.lastKnownState {
        case .unknown:
            return "Refresh to load live usage for this account."
        case .active:
            return "Live usage will refresh automatically."
        case .needsLogin:
            return "Open Chrome to sign in to \(profile.provider.displayName) again."
        case .failed:
            return "Refresh this profile to retry the last failed request."
        }
    }

    private func setRefreshingState(for profileID: UUID, isRefreshing: Bool) {
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]
        let targetState = snapshot.usage == nil && isRefreshing ? PlusProfileState.loading : snapshot.state
        profiles[index] = snapshot.updating(
            state: targetState,
            statusMessage: isRefreshing ? .some(nil) : nil,
            isRefreshing: isRefreshing
        )
    }

    private func applyFailure(
        _ error: ChatGPTAPIError,
        to profileID: UUID,
        preserveUsage: Bool
    ) {
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]
        var updatedProfile = snapshot.profile

        switch error {
        case .unauthorized:
            updatedProfile.lastKnownState = .needsLogin
            profiles[index] = snapshot.updating(
                profile: updatedProfile,
                state: .needsLogin,
                usage: preserveUsage ? nil : .some(nil),
                statusMessage: .some(
                    "Open Chrome to sign in to \(snapshot.profile.provider.displayName) again."
                ),
                isRefreshing: false
            )
        default:
            updatedProfile.lastKnownState = .failed
            profiles[index] = snapshot.updating(
                profile: updatedProfile,
                state: .failed,
                usage: preserveUsage ? nil : .some(nil),
                statusMessage: .some(error.errorDescription ?? "This profile could not be refreshed."),
                isRefreshing: false
            )
        }

        persistProfiles()
        updateDashboardStatus()
    }

    private func markChromeSignInNeedsMoreTime(profileID: UUID) {
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]
        var updatedProfile = snapshot.profile
        updatedProfile.lastKnownState = .needsLogin
        profiles[index] = snapshot.updating(
            profile: updatedProfile,
            state: .needsLogin,
            usage: .some(nil),
            statusMessage: .some(
                "\(snapshot.profile.provider.displayName) session was not ready. "
                    + "Stay signed in, then sync again."
            ),
            isRefreshing: false
        )
        persistProfiles()
        updateDashboardStatus()
    }

    private func updateDashboardStatus() {
        if profiles.isEmpty {
            dashboardStatus = .empty
            return
        }

        let stateCounts = profileStateCounts

        if isRefreshing && stateCounts.ready == 0 {
            dashboardStatus = .refreshing
            return
        }

        if stateCounts.ready == profiles.count {
            dashboardStatus = .ready
            return
        }

        if stateCounts.ready == 0 && stateCounts.needsLogin == profiles.count {
            dashboardStatus = .needsLogin
            return
        }

        if stateCounts.ready == 0 && stateCounts.failed > 0 {
            dashboardStatus = .failed
            return
        }

        if stateCounts.hasKnownState {
            dashboardStatus = .mixedAttention
            return
        }

        dashboardStatus = .refreshing
    }

    private func makeGlobalStatusMessage() -> String? {
        if profiles.isEmpty {
            return "Add a profile, then sign in one by one."
        }

        let stateCounts = profileStateCounts
        let loginCount = stateCounts.needsLogin
        let failureCount = stateCounts.failed

        if loginCount == 0 && failureCount == 0 {
            return nil
        }

        var parts: [String] = []
        if loginCount > 0 {
            parts.append(loginCount == 1 ? "1 profile needs login" : "\(loginCount) profiles need login")
        }
        if failureCount > 0 {
            parts.append(failureCount == 1 ? "1 profile failed to refresh" : "\(failureCount) profiles failed to refresh")
        }

        return parts.joined(separator: " · ")
    }

    private func mostUrgentHealthyProfile() -> PlusProfileSnapshot? {
        profiles.lazy
            .filter { $0.state == .ready && $0.usage != nil }
            .min { lhs, rhs in
                let lhsRemaining = lhs.usage?.fiveHourRemainingPercent ?? 101
                let rhsRemaining = rhs.usage?.fiveHourRemainingPercent ?? 101

                if lhsRemaining == rhsRemaining {
                    let lhsReset = lhs.usage?.primaryWindow.resetAt ?? .distantFuture
                    let rhsReset = rhs.usage?.primaryWindow.resetAt ?? .distantFuture

                    if lhsReset == rhsReset {
                        return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
                    }

                    return lhsReset < rhsReset
                }

                return lhsRemaining < rhsRemaining
            }
    }

    private var profileStateCounts: ProfileStateCounts {
        profiles.reduce(into: ProfileStateCounts()) { counts, snapshot in
            if snapshot.state == .ready, snapshot.usage != nil {
                counts.ready += 1
            } else if snapshot.state == .needsLogin {
                counts.needsLogin += 1
            } else if snapshot.state == .failed {
                counts.failed += 1
            }
        }
    }

    private func compactStatusLabel(for label: String) -> String {
        DisplayFormatter.compactStatusProfileLabel(label)
    }

    private func indexOfProfile(_ profileID: UUID) -> Int? {
        profiles.firstIndex(where: { $0.id == profileID })
    }

    @discardableResult
    private func persistProfiles() -> Bool {
        var seenProfileIDs: Set<UUID> = []
        let uniqueProfiles = profiles.filter { snapshot in
            seenProfileIDs.insert(snapshot.id).inserted
        }

        profiles = uniqueProfiles.enumerated().map { index, snapshot in
            var updatedProfile = snapshot.profile
            updatedProfile.sortOrder = index
            return snapshot.updating(profile: updatedProfile)
        }

        do {
            try catalogStore.saveProfiles(profiles.map(\.profile))
            syncScheduler.update(profiles: profiles.map(\.profile), trusted: true)
            return true
        } catch {
            syncScheduler.update(profiles: profiles.map(\.profile), trusted: false)
            statusMessage = "The profile list could not be saved locally."
            return false
        }
    }
}
