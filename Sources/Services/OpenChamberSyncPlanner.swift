import Foundation

enum OpenChamberSyncError: LocalizedError, Equatable {
    case catalogUnavailable, changed, stateUnavailable
    var errorDescription: String? {
        switch self {
        case .catalogUnavailable: "Save the profile list successfully before syncing OpenChamber."
        case .changed: "Accounts changed during sync. Sync will retry."
        case .stateUnavailable: "OpenChamber sync history could not be saved or read. Automatic removal is paused."
        }
    }
}

struct OpenChamberSyncCatalog: Sendable {
    let generation: UInt64
    let profiles: [PlusProfile]
    let isTrusted: Bool
}

struct OpenChamberSyncAccount: Equatable, Sendable {
    let id: String
    let label: String
    let active: Bool
    let identity: OpenCodeOpenAIIdentity
    init(id: String, label: String, active: Bool, identity: OpenCodeOpenAIIdentity) {
        self.id = id; self.label = label; self.active = active; self.identity = identity
    }
    init(_ entry: OpenCodeStoredCredential) throws {
        self.init(id: entry.id, label: entry.label, active: entry.active, identity: try entry.openAIIdentity())
    }
}

struct OpenChamberSyncPlan: Sendable {
    var restoreProfileIDs: [UUID] = []
    var bindings: [UUID: String] = [:]
    var renames: [String: String] = [:]
    var removeIDs: [String] = []
    var replacementActiveID: String?
    var needsSignInProfileIDs: Set<UUID> = []
    var pendingCredentialIDs: Set<String> = []
}

enum OpenChamberSyncPlanner {
    static func plan(catalog: OpenChamberSyncCatalog, accounts: [OpenChamberSyncAccount], savedBindings: [String: String],
                     state: OpenChamberSyncState, now: Date) throws -> OpenChamberSyncPlan {
        guard catalog.isTrusted else { throw OpenChamberSyncError.catalogUnavailable }
        guard state.hasBaseline, Set(accounts.map(\.id)).count == accounts.count else { throw OpenChamberSyncError.stateUnavailable }
        var plan = OpenChamberSyncPlan()
        var retained: Set<String> = []
        var chosen: [String: String] = [:]
        for profile in catalog.profiles.filter({ $0.provider == .codex }).sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let identity = profile.openCodeOpenAIAccount else {
                plan.needsSignInProfileIDs.insert(profile.id); continue
            }
            if let id = chosen[identity.storageKey] { plan.bindings[profile.id] = id; continue }
            let matching = accounts.filter { $0.identity.matches(identity) }.sorted {
                if $0.active != $1.active { return $0.active }
                let a = $0.id == savedBindings[identity.storageKey], b = $1.id == savedBindings[identity.storageKey]
                if a != b { return a }
                return $0.id < $1.id
            }
            guard let account = matching.first else { plan.restoreProfileIDs.append(profile.id); continue }
            chosen[identity.storageKey] = account.id
            retained.insert(account.id)
            plan.bindings[profile.id] = account.id
            if plan.replacementActiveID == nil { plan.replacementActiveID = account.id }
            if profile.label != account.label { plan.renames[account.id] = profile.label }
        }
        for account in accounts where !retained.contains(account.id) {
            if let since = state.pendingSince[account.id], now.timeIntervalSince(since) < 900 {
                plan.pendingCredentialIDs.insert(account.id)
            } else { plan.removeIDs.append(account.id) }
        }
        plan.removeIDs.sort()
        return plan
    }
}

struct OpenChamberSyncResult: Equatable, Sendable {
    let matchedCount: Int
    let totalCount: Int
    let needsSignInProfileIDs: Set<UUID>
    let pendingCredentialCount: Int
    let deferredActiveRemoval: Bool
    var message: String {
        if deferredActiveRemoval { return "Waiting for OpenChamber’s running sessions before removing its active login." }
        if pendingCredentialCount > 0 { return "Waiting for Save current sign-in (\(pendingCredentialCount) new login\(pendingCredentialCount == 1 ? "" : "s"))." }
        if !needsSignInProfileIDs.isEmpty { return "\(matchedCount) of \(totalCount) profiles linked; \(needsSignInProfileIDs.count) need sign-in." }
        return "OpenChamber synced · \(matchedCount) profile\(matchedCount == 1 ? "" : "s")"
    }
}
