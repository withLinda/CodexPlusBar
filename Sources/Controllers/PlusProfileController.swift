import Foundation
import Observation
import WebKit

@Observable
@MainActor
final class PlusProfileController {
    var profiles: [PlusProfileSnapshot] = []
    var selectedProfileID: UUID?
    var statusMessage: String?
    var isRefreshing = false
    var dashboardStatus: PlusDashboardStatus = .empty

    @ObservationIgnored private let catalogStore: ProfileCatalogStore
    @ObservationIgnored private let dataService: PlusProfileDataServing
    @ObservationIgnored private let autoRefreshIntervalNanoseconds: UInt64
    @ObservationIgnored private let maxConcurrentProfileRefreshes: Int
    @ObservationIgnored private let autoRefreshSleep: @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    init(
        catalogStore: ProfileCatalogStore = ProfileCatalogStore(),
        dataService: PlusProfileDataServing = PlusProfileDataService(),
        autoRefreshInterval: TimeInterval = 300,
        maxConcurrentProfileRefreshes: Int = 3,
        autoRefreshSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        autoStart: Bool = true
    ) {
        self.catalogStore = catalogStore
        self.dataService = dataService
        self.autoRefreshIntervalNanoseconds = UInt64(autoRefreshInterval * 1_000_000_000)
        self.maxConcurrentProfileRefreshes = max(1, maxConcurrentProfileRefreshes)
        self.autoRefreshSleep = autoRefreshSleep
        loadStoredProfiles()

        if autoStart {
            bootstrapTask = Task { [weak self] in
                await self?.refreshAll()
            }
            autoRefreshTask = Task { [weak self] in
                await self?.runAutoRefreshLoop()
            }
        }
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

    var readyProfiles: [PlusProfileSnapshot] {
        profiles.filter { $0.state == .ready && $0.usage != nil }
    }

    var needsLoginProfiles: [PlusProfileSnapshot] {
        profiles.filter { $0.state == .needsLogin }
    }

    var failedProfiles: [PlusProfileSnapshot] {
        profiles.filter { $0.state == .failed }
    }

    var statusBarSymbolName: String {
        if let urgent = mostUrgentHealthyProfile(),
           let remaining = urgent.usage?.fiveHourRemainingPercent,
           remaining <= 20 {
            return "exclamationmark.triangle.fill"
        }

        return dashboardStatus.symbolName
    }

    func statusBarText(referenceDate: Date = .now) -> String {
        if let urgent = mostUrgentHealthyProfile() {
            let label = compactLabel(for: urgent.profile.displayLabel)
            return "\(label) 5H \(urgent.fiveHourText)"
        }

        if isRefreshing {
            return profiles.isEmpty ? "Checking…" : "Refreshing…"
        }

        switch dashboardStatus {
        case .empty:
            return "Add profile"
        case .needsLogin:
            return "Login needed"
        case .failed:
            return "Check profiles"
        case .mixedAttention:
            return "\(readyProfiles.count)/\(profiles.count) ready"
        case .refreshing:
            return "Refreshing…"
        case .ready:
            if let refreshedAt = profiles.compactMap(\.lastRefreshAt).max(),
               let updated = DisplayFormatter.updatedText(refreshedAt, referenceDate: referenceDate) {
                return updated.replacingOccurrences(of: "Updated ", with: "")
            }

            return "\(readyProfiles.count) ready"
        }
    }

    func addProfile(label: String? = nil) {
        let nextIndex = profiles.count + 1
        let newProfile = PlusProfile(
            id: UUID(),
            label: label ?? "Account \(nextIndex)",
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
                statusMessage: "Sign in with this account in the web view below.",
                isRefreshing: false
            )
        )
        selectedProfileID = newProfile.id
        persistProfiles()
        updateDashboardStatus()
    }

    func selectProfile(id: UUID?) {
        selectedProfileID = id ?? profiles.first?.id
    }

    func updateLabel(for profileID: UUID, label: String) {
        guard let index = indexOfProfile(profileID) else { return }
        var updatedProfile = profiles[index].profile
        updatedProfile.label = label
        profiles[index] = profiles[index].updating(profile: updatedProfile)
        persistProfiles()
    }

    func moveSelectedProfileUp() {
        guard let selectedProfileID,
              let index = indexOfProfile(selectedProfileID),
              index > 0 else { return }

        profiles.swapAt(index, index - 1)
        persistProfiles()
    }

    func moveSelectedProfileDown() {
        guard let selectedProfileID,
              let index = indexOfProfile(selectedProfileID),
              index < profiles.count - 1 else { return }

        profiles.swapAt(index, index + 1)
        persistProfiles()
    }

    func refreshAll() async {
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

    func clearSession(for profileID: UUID) async {
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
                statusMessage: .some("Sign in again to restore this account."),
                isRefreshing: false
            )
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
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]

        do {
            try await dataService.removeProfileData(for: snapshot.profile)
            profiles.remove(at: index)

            if selectedProfileID == profileID {
                selectedProfileID = profiles.indices.contains(index)
                    ? profiles[index].id
                    : profiles.last?.id
            }

            persistProfiles()
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

    func dataStore(for profileID: UUID) -> WKWebsiteDataStore? {
        guard let snapshot = profiles.first(where: { $0.id == profileID }) else {
            return nil
        }

        return dataService.dataStore(for: snapshot.profile)
    }

    private func refreshProfile(id profileID: UUID, isBackgroundBatch: Bool) async {
        guard let index = indexOfProfile(profileID) else { return }
        let snapshot = profiles[index]
        setRefreshingState(for: profileID, isRefreshing: true)

        do {
            let result = try await dataService.refreshProfile(snapshot.profile)
            var updatedProfile = snapshot.profile
            updatedProfile.detectedNote = result.detectedNote
            updatedProfile.lastRefreshAt = result.usage.fetchedAt
            updatedProfile.lastKnownState = .active

            profiles[index] = snapshot.updating(
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

        do {
            storedProfiles = try catalogStore.loadProfiles()
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
        updateDashboardStatus()
    }

    private func runAutoRefreshLoop() async {
        while Task.isCancelled == false {
            do {
                try await autoRefreshSleep(autoRefreshIntervalNanoseconds)
            } catch {
                return
            }

            if Task.isCancelled {
                return
            }

            await refreshAll()
        }
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
            return "Sign in again to restore this account."
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
                statusMessage: .some("Sign in again to restore this account."),
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

    private func updateDashboardStatus() {
        if profiles.isEmpty {
            dashboardStatus = .empty
            return
        }

        if isRefreshing && readyProfiles.isEmpty {
            dashboardStatus = .refreshing
            return
        }

        if readyProfiles.count == profiles.count {
            dashboardStatus = .ready
            return
        }

        if readyProfiles.isEmpty && needsLoginProfiles.count == profiles.count {
            dashboardStatus = .needsLogin
            return
        }

        if readyProfiles.isEmpty && failedProfiles.isEmpty == false {
            dashboardStatus = .failed
            return
        }

        if readyProfiles.isEmpty == false || needsLoginProfiles.isEmpty == false || failedProfiles.isEmpty == false {
            dashboardStatus = .mixedAttention
            return
        }

        dashboardStatus = .refreshing
    }

    private func makeGlobalStatusMessage() -> String? {
        if profiles.isEmpty {
            return "Add a profile, then sign in one by one."
        }

        let loginCount = needsLoginProfiles.count
        let failureCount = failedProfiles.count

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
        readyProfiles.sorted { lhs, rhs in
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
        }.first
    }

    private func compactLabel(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else {
            return trimmed
        }

        return String(trimmed.prefix(11)) + "…"
    }

    private func indexOfProfile(_ profileID: UUID) -> Int? {
        profiles.firstIndex(where: { $0.id == profileID })
    }

    private func persistProfiles() {
        profiles = profiles.enumerated().map { index, snapshot in
            var updatedProfile = snapshot.profile
            updatedProfile.sortOrder = index
            return snapshot.updating(profile: updatedProfile)
        }

        do {
            try catalogStore.saveProfiles(profiles.map(\.profile))
        } catch {
            statusMessage = "The profile list could not be saved locally."
        }
    }
}
