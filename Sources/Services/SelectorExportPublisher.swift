import Foundation

struct SelectorRefreshTicket: Equatable, Sendable {
    let profileID: UUID
    let identityKey: String
    let bindingID: String
    let generation: UUID
}

@MainActor protocol SelectorExportPublishing: AnyObject {
    func update(profiles: [PlusProfileSnapshot], observations: [UUID: SelectorObservation], trusted: Bool)
    func invalidate(profileID: UUID)
    func beginRefresh(profileID: UUID) async -> SelectorRefreshTicket?
    func completeRefresh(ticket: SelectorRefreshTicket, observation: SelectorObservation?) async
    func bindingsChanged()
    func start()
    func stop()
}

@MainActor
final class SelectorExportPublisher: SelectorExportPublishing {
    private struct Binding { let id: String; let observedAt: Date }
    private let binding: @MainActor (OpenCodeOpenAIIdentity) async throws -> String?
    private let write: @MainActor (SelectorExport) throws -> Void
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let sourceInstanceID = UUID().uuidString
    private var sequence: Int64 = 0
    private var profiles: [PlusProfileSnapshot] = []
    private var observations: [UUID: SelectorObservation] = [:]
    private var generations: [UUID: UUID] = [:]
    private var bindings: [UUID: Binding] = [:]
    private var trusted = false
    private var started = false
    private var hasPublished = false
    private var publishing = false
    private var lifecycle = UUID()
    private var heartbeat: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private(set) var writeFailed = false

    init(binding: @escaping @MainActor (OpenCodeOpenAIIdentity) async throws -> String?,
         write: @escaping @MainActor (SelectorExport) throws -> Void,
         now: @escaping @MainActor () -> Date = { .now },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.binding = binding; self.write = write; self.now = now; self.sleep = sleep
    }

    convenience init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let store = SelectorExportStore(homeDirectory: homeDirectory)
        let bindings = OpenCodeSignInSnapshotStore(homeDirectory: homeDirectory)
        self.init(binding: { identity in
            try await OpenCodeOperationGate.shared.withOperation { try bindings.binding(identity: identity) }
        }, write: { try store.write($0) })
    }

    deinit { heartbeat?.cancel(); debounce?.cancel() }

    func update(profiles next: [PlusProfileSnapshot], observations incoming: [UUID: SelectorObservation], trusted: Bool) {
        var invalidated = self.trusted != trusted
        for old in profiles {
            let nextProfile = next.first { $0.id == old.id }
            if nextProfile?.profile.openCodeOpenAIAccount?.storageKey != old.profile.openCodeOpenAIAccount?.storageKey
                || nextProfile?.state == .needsLogin {
                observations.removeValue(forKey: old.id); bindings.removeValue(forKey: old.id)
                generations[old.id] = UUID(); invalidated = true
            }
        }
        profiles = next; self.trusted = trusted
        for profile in next where generations[profile.id] == nil { generations[profile.id] = UUID() }
        // Controller integrations use tickets; this entry point accepts only already-verified same-identity data.
        for (id, evidence) in incoming where next.contains(where: { $0.id == id && $0.profile.openCodeOpenAIAccount?.storageKey == evidence.identityKey && $0.state != .needsLogin }) {
            observations[id] = evidence
        }
        if invalidated { publishCached() }
        schedule()
    }

    func invalidate(profileID: UUID) {
        observations.removeValue(forKey: profileID)
        generations[profileID] = UUID()
        publishCached()
    }

    func beginRefresh(profileID: UUID) async -> SelectorRefreshTicket? {
        generations[profileID] = UUID()
        guard let identity = identity(profileID), let generation = generations[profileID] else { return nil }
        let lifecycle = lifecycle
        guard let id = try? await binding(identity), generation == generations[profileID],
              lifecycle == self.lifecycle, identity.storageKey == self.identity(profileID)?.storageKey else { return nil }
        acceptBinding(id, profileID: profileID)
        return SelectorRefreshTicket(profileID: profileID, identityKey: identity.storageKey, bindingID: id,
                                     generation: generations[profileID]!)
    }

    func completeRefresh(ticket: SelectorRefreshTicket, observation: SelectorObservation?) async {
        let lifecycle = lifecycle
        guard ticket.generation == generations[ticket.profileID], let identity = identity(ticket.profileID),
              ticket.identityKey == identity.storageKey else { return }
        guard let current = try? await binding(identity), lifecycle == self.lifecycle, ticket.generation == generations[ticket.profileID],
              ticket.identityKey == self.identity(ticket.profileID)?.storageKey else { return }
        acceptBinding(current, profileID: ticket.profileID)
        guard current == ticket.bindingID, ticket.generation == generations[ticket.profileID] else { return }
        if let observation, observation.identityKey == ticket.identityKey {
            let previous = observations[ticket.profileID]
            observations[ticket.profileID] = SelectorObservation(identityKey: observation.identityKey, accountID: observation.accountID,
                usage: observation.usage,
                entitlement: observation.unavailableReasons.contains("expiry-refresh-failed") ? previous?.entitlement : observation.entitlement,
                unavailableReasons: observation.unavailableReasons)
        } else { observations.removeValue(forKey: ticket.profileID) }
        schedule()
    }

    func bindingsChanged() { schedule(immediate: true) }

    func start() {
        guard !started else { return }
        started = true; schedule(immediate: true)
        let sleep = sleep
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(30) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.publishNow()
            }
        }
    }

    func stop() {
        lifecycle = UUID()
        for id in generations.keys { generations[id] = UUID() }
        started = false; heartbeat?.cancel(); heartbeat = nil; debounce?.cancel(); debounce = nil
    }

    func publishNow() async {
        guard !publishing else { schedule(); return }
        publishing = true
        let lifecycle = lifecycle
        defer { publishing = false }
        for profile in profiles {
            guard let identity = identity(profile.id), let generation = generations[profile.id] else { continue }
            do {
                let id = try await binding(identity)
                guard lifecycle == self.lifecycle else { return }
                guard generation == generations[profile.id], identity.storageKey == self.identity(profile.id)?.storageKey else { continue }
                if let id { acceptBinding(id, profileID: profile.id) }
                else { bindings.removeValue(forKey: profile.id); invalidate(profileID: profile.id) }
            } catch OpenCodeOpenAIAuthError.busy {
                guard lifecycle == self.lifecycle else { return }
                schedule()
            } catch {
                guard lifecycle == self.lifecycle else { return }
                bindings.removeValue(forKey: profile.id); invalidate(profileID: profile.id)
            }
        }
        publishCached(force: true)
    }

    private func identity(_ id: UUID) -> OpenCodeOpenAIIdentity? {
        guard let profile = profiles.first(where: { $0.id == id }), profile.profile.provider == .codex,
              profile.state != .needsLogin else { return nil }
        return profile.profile.openCodeOpenAIAccount
    }

    private func acceptBinding(_ id: String, profileID: UUID) {
        if let old = bindings[profileID], old.id != id {
            observations.removeValue(forKey: profileID); generations[profileID] = UUID()
        }
        bindings[profileID] = Binding(id: id, observedAt: now())
    }

    private func publishCached(force: Bool = false) {
        guard force || started || hasPublished else { return }
        do {
            let rows = try profiles.compactMap { profile -> SelectorExport.Account? in
                guard identity(profile.id) != nil, let binding = bindings[profile.id] else { return nil }
                return try SelectorExport.account(profile: profile.profile, credentialID: binding.id,
                    bindingObservedAt: binding.observedAt, observation: observations[profile.id])
            }
            guard sequence < 9_007_199_254_740_991 else { throw CocoaError(.coderInvalidValue) }
            let value = SelectorExport(schemaVersion: 1, sourceInstanceID: sourceInstanceID, sequence: sequence,
                generatedAtMs: try SelectorExport.milliseconds(now()), catalogTrusted: trusted, accounts: rows)
            try write(value); sequence += 1; writeFailed = false; hasPublished = true
        } catch { writeFailed = true }
    }

    private func schedule(immediate: Bool = false) {
        guard started else { return }
        debounce?.cancel()
        let sleep = sleep
        debounce = Task { [weak self] in
            do { if !immediate { try await sleep(0.25) } } catch { return }
            guard !Task.isCancelled else { return }
            await self?.publishNow()
        }
    }
}
