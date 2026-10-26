import Foundation
import Observation

@Observable @MainActor
final class OpenChamberSyncScheduler {
    private(set) var result: OpenChamberSyncResult?
    private(set) var message: String?
    private(set) var isSyncing = false
    @ObservationIgnored private let service: any OpenChamberSyncServing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var catalog = OpenChamberSyncCatalog(generation: 0, profiles: [], isTrusted: false)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var manual = false
    @ObservationIgnored private var enabled: Bool
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var observer: SyncPreferenceObserver?

    init(service: any OpenChamberSyncServing = OpenChamberSyncService(), defaults: UserDefaults = .standard,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.service = service; self.defaults = defaults; self.sleep = sleep
        enabled = OpenChamberSyncPreference.enabled(in: defaults)
        observer = SyncPreferenceObserver { [weak self] in
            Task { @MainActor [weak self] in self?.preferenceChanged() }
        }
    }
    deinit { operation?.cancel(); debounce?.cancel(); retry?.cancel() }

    func update(profiles: [PlusProfile], trusted: Bool) {
        let changed = catalog.isTrusted != trusted || keys(catalog.profiles) != keys(profiles)
        catalog = .init(generation: catalog.generation &+ (changed ? 1 : 0), profiles: profiles, isTrusted: trusted)
        if changed {
            operation?.cancel(); result = nil
            message = trusted ? "OpenChamber sync pending…" : OpenChamberSyncError.catalogUnavailable.localizedDescription
            schedule()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        schedule(immediate: true)
        let sleep = sleep
        retry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(OpenChamberSyncPreference.retryInterval) } catch { return }
                guard !Task.isCancelled, self != nil else { return }
                await self?.syncNow()
            }
        }
    }
    func stop() {
        started = false
        retry?.cancel(); retry = nil
        debounce?.cancel(); debounce = nil
        operation?.cancel()
        invalidate()
    }
    func preferenceChanged() {
        let next = OpenChamberSyncPreference.enabled(in: defaults)
        guard next != enabled else { return }
        enabled = next
        invalidate()
        debounce?.cancel(); operation?.cancel()
        result = nil; message = enabled ? "OpenChamber sync pending…" : "OpenChamber automatic sync is off."
        if enabled { schedule(immediate: true) }
    }
    func pauseForManualOperation() async {
        manual = true
        invalidate()
        debounce?.cancel(); operation?.cancel()
        await operation?.value
    }
    func resumeAfterManualOperation() { manual = false; schedule() }

    func syncNow() async {
        preferenceChanged()
        if let operation {
            let wasCancelled = operation.isCancelled
            await operation.value
            if !wasCancelled { return }
        }
        guard operation == nil, enabled, !manual, !Task.isCancelled else { return }
        guard catalog.isTrusted else { message = OpenChamberSyncError.catalogUnavailable.localizedDescription; return }
        let input = catalog, service = service
        isSyncing = true; message = "Syncing OpenChamber…"
        let task = Task { [weak self] in
            do {
                let result = try await service.reconcile(catalog: input, isCurrent: { [weak self] generation in
                    await self?.isCurrent(generation) == true
                })
                if self?.isCurrent(input.generation) == true, !Task.isCancelled {
                    self?.result = result; self?.message = result.message
                }
            } catch {
                if self?.isCurrent(input.generation) == true, !Task.isCancelled {
                    self?.result = nil
                    self?.message = Self.safeMessage(error)
                }
            }
            self?.isSyncing = false
            self?.operation = nil
        }
        operation = task
        await task.value
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        enabled && OpenChamberSyncPreference.enabled(in: defaults) && !manual && catalog.isTrusted && catalog.generation == generation
    }
    private func invalidate() { catalog = .init(generation: catalog.generation &+ 1, profiles: catalog.profiles, isTrusted: catalog.isTrusted) }
    private func schedule(immediate: Bool = false) {
        guard started, enabled, !manual else { return }
        debounce?.cancel()
        let sleep = sleep
        debounce = Task { [weak self] in
            do { if !immediate { try await sleep(OpenChamberSyncPreference.debounceInterval) } } catch { return }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }
    private struct Key: Equatable {
        let id: UUID; let label: String; let order: Int; let identity: OpenCodeOpenAIIdentity?
    }
    private func keys(_ profiles: [PlusProfile]) -> [Key] {
        profiles.filter { $0.provider == .codex }.map { Key(id: $0.id, label: $0.label, order: $0.sortOrder, identity: $0.openCodeOpenAIAccount) }
    }
    private static func safeMessage(_ error: any Error) -> String {
        if let error = error as? OpenChamberSyncError { return error.localizedDescription }
        if let error = error as? OpenCodeCredentialError { return error.localizedDescription }
        if let error = error as? OpenCodeOpenAIAuthError { return error.localizedDescription }
        return "OpenChamber sync could not finish. It will retry."
    }
}

/// Immutable Foundation observer token; only NotificationCenter manages its state.
/// This wrapper permits deterministic removal from a nonisolated deinit.
private final class SyncPreferenceObserver: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(changed: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in changed() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
