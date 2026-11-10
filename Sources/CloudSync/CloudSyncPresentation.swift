import Foundation
import Observation
import CloudKit

enum CloudSyncIssue: Equatable {
    case network, account, keychain, repair, changed, storage, quota
    init(_ error: any Error) {
        if error is CloudKeyStoreError { self = .keychain }
        else if error is URLError { self = .network }
        else if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: self = .account
            case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited: self = .network
            case .quotaExceeded: self = .quota
            default: self = .storage
            }
        } else if error as? CloudTransportError == .accountChanged { self = .account }
        else if error as? CodexSignInError == .unauthorized || error as? ChatGPTAPIError == .unauthorized ||
                    error as? OpenCodeOpenAIVerificationError == .reauthenticationRequired ||
                    error as? OpenCodeOpenAIVerificationError == .unauthorized || error is CloudSessionAdoptionError { self = .repair }
        else if error as? OpenCodeOpenAIVerificationError == .unavailable || error as? CodexSignInError == .unavailable { self = .network }
        else if error is CloudSessionError || error is CancellationError { self = .changed }
        else { self = .storage }
    }
    var message: String {
        switch self {
        case .network: "Waiting for a connection. Try again when you’re online."
        case .account: "Sign in to iCloud in System Settings, then enable sync on this Mac."
        case .keychain: "Waiting for iCloud Keychain. Enable Passwords & Keychain on both Macs, then retry."
        case .repair: "This saved login needs Repair or a fresh sign-in. Switch still activates a saved local login."
        case .changed: "The account or saved session changed. Reload the available sessions and try again."
        case .storage: "Sync could not finish. Your local accounts are retained. Retry to continue."
        case .quota: "iCloud storage is full. Free space, then retry."
        }
    }
}

enum CloudSyncDisplayStatus: String, CaseIterable {
    case off, initialMerge, syncing, upToDate, pending, waitingForNetwork, waitingForAccount, waitingForKeychain, pausedForTransfer, pausedAfterRestore, error
    var title: String {
        switch self {
        case .off: "Off on this Mac"
        case .initialMerge: "Merging accounts…"
        case .syncing: "Syncing…"
        case .upToDate: "Up to date"
        case .pending: "Changes pending"
        case .waitingForNetwork: "Waiting for network"
        case .waitingForAccount: "Waiting for iCloud sign-in"
        case .waitingForKeychain: "Waiting for iCloud Keychain"
        case .pausedForTransfer: "Paused for backup or transfer"
        case .pausedAfterRestore: "Paused after restore — enable sync to merge"
        case .error: "Sync needs attention"
        }
    }
}

@MainActor protocol CloudSyncPresenting: AnyObject {
    var enabled: Bool { get }
    var includesSessions: Bool { get }
    var busy: Bool { get }
    var isTransferring: Bool { get }
    var deliveryDegraded: Bool { get }
    var epoch: UUID? { get }
    var canSyncNow: Bool { get }
    var canRetry: Bool { get }
    var status: CloudSyncDisplayStatus { get }
    var statusMessage: String? { get }
    var lastSuccessfulSync: Date? { get }
    var sessions: [CloudSessionSummary] { get }
    var sessionMessage: String? { get }
    var failure: CloudSyncIssue? { get }
    func setEnabled(_ value: Bool) async
    func setIncludesSessions(_ value: Bool) async
    func syncNow() async
    func selectProfile(_ id: UUID?) async
    func reload() async
    func canAdopt(_ summary: CloudSessionSummary) -> Bool
    func adopt(_ summary: CloudSessionSummary) async throws
    func retry() async throws
}

@Observable @MainActor final class CloudSyncPresentation: CloudSyncPresenting {
    let coordinator: CloudSyncCoordinator
    private(set) var selectedProfileID: UUID?
    private(set) var sessions: [CloudSessionSummary] = []
    private(set) var busy = false
    private(set) var failure: CloudSyncIssue?
    private(set) var sessionMessage: String?
    @ObservationIgnored private var loadedEpoch: UUID?
    @ObservationIgnored private var failedRequest: CloudSessionAdoptionRequest?
    @ObservationIgnored private var failedOwner: CloudOwner?
    @ObservationIgnored private var action: Task<Void, Error>?
    @ObservationIgnored private var loadID = UUID()
    init(coordinator: CloudSyncCoordinator) { self.coordinator = coordinator }
    var enabled: Bool { coordinator.isEnabled }
    var isTransferring: Bool { coordinator.isTransferring }
    var deliveryDegraded: Bool { coordinator.deliveryDegraded }
    var epoch: UUID? { coordinator.epoch }
    var includesSessions: Bool { coordinator.includesSessions }
    var lastSuccessfulSync: Date? { coordinator.lastSuccessfulSync }
    var canSyncNow: Bool { enabled && !busy && !coordinator.isTransferring && coordinator.status != .paused && coordinator.status != .syncing }
    var canRetry: Bool {
        guard !busy, enabled, includesSessions, let request = failedRequest,
              selectedProfileID == request.profileID, failedOwner == coordinator.owner else { return false }
        return coordinator.canAdoptSession(for: request.profileID)
    }
    var status: CloudSyncDisplayStatus {
        if coordinator.isTransferring { return .pausedForTransfer }
        if coordinator.status == .off { return .off }
        if coordinator.status == .paused { return coordinator.issue == nil ? .pausedAfterRestore : .error }
        if coordinator.status == .needsConsent || coordinator.issue == .account { return .waitingForAccount }
        if coordinator.issue == .keychain { return .waitingForKeychain }
        if coordinator.issue == .network { return .waitingForNetwork }
        if coordinator.issue != nil { return .error }
        switch coordinator.status {
        case .syncing: return coordinator.isInitialMerge ? .initialMerge : .syncing
        case .upToDate: return failure == nil ? .upToDate : .error
        case .pending: return .pending
        case .unavailable, .failed: return .error
        default: return .off
        }
    }
    var statusMessage: String? {
        if coordinator.status == .off { return nil }
        if coordinator.status == .unavailable { return "This build does not have iCloud sync enabled." }
        return (failure ?? coordinator.issue)?.message
    }
    func setEnabled(_ value: Bool) async {
        guard !busy, !coordinator.isTransferring else { return }
        busy = true; defer { busy = false }
        await coordinator.setEnabled(value)
        await reload()
    }
    func setIncludesSessions(_ value: Bool) async {
        guard !busy, enabled, !coordinator.isTransferring else { return }
        busy = true; defer { busy = false }
        await coordinator.setIncludesSessions(value)
        await reload()
    }
    func syncNow() async {
        guard canSyncNow else { return }
        busy = true; defer { busy = false }
        await coordinator.syncNow(); await reload()
    }
    func selectProfile(_ id: UUID?) async {
        if selectedProfileID != id {
            action?.cancel(); failedRequest = nil; failedOwner = nil
            failure = nil; sessionMessage = nil
        }
        selectedProfileID = id
        await reload()
    }
    func reload() async {
        let load = UUID(); loadID = load
        let epoch = coordinator.epoch
        sessions = []; loadedEpoch = nil
        guard let id = selectedProfileID, enabled, includesSessions, epoch != nil else { return }
        do {
            let values = try await coordinator.sessionSummaries(for: id)
            guard loadID == load, selectedProfileID == id, coordinator.epoch == epoch else { return }
            sessions = values; loadedEpoch = epoch
            if failedRequest == nil { failure = nil }
        } catch { if loadID == load { failure = CloudSyncIssue(error) } }
    }
    func canAdopt(_ summary: CloudSessionSummary) -> Bool {
        !busy && enabled && includesSessions && summary.profileID == selectedProfileID &&
            loadedEpoch != nil && loadedEpoch == coordinator.epoch && sessions.contains(summary) &&
            coordinator.canAdoptSession(for: summary.profileID)
    }
    func adopt(_ summary: CloudSessionSummary) async throws {
        guard canAdopt(summary) else { throw CloudSessionError.unavailable }
        try await perform(.init(profileID: summary.profileID, recordName: summary.recordName, sourceRevision: summary.revision))
    }
    func retry() async throws {
        guard canRetry, let request = failedRequest else { throw CloudSessionError.unavailable }
        try await perform(request)
    }
    private func perform(_ request: CloudSessionAdoptionRequest) async throws {
        busy = true; failure = nil; sessionMessage = nil
        failedRequest = request; failedOwner = coordinator.owner
        let task = Task { try await coordinator.adoptSession(request) }
        action = task
        defer { busy = false; action = nil }
        do {
            try await task.value
            guard selectedProfileID == request.profileID else { return }
            failedRequest = nil
            sessionMessage = "Saved session ready. A working local login is kept; use Switch to activate a native login."
            await reload()
        } catch {
            if selectedProfileID == request.profileID { failure = CloudSyncIssue(error) }
            throw error
        }
    }
}
