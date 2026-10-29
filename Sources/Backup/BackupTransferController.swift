import AppKit
import Observation
import UniformTypeIdentifiers

enum BackupTransferMode { case export, restore }

enum BackupTransferPhase {
    case password, preview, working(String), exported(URL), restored(Int), recoveryNeeded
}

@Observable @MainActor
final class BackupTransferController {
    static let contentType = UTType(exportedAs: "com.linda.CodexPlusBar.backup", conformingTo: .data)
    var mode: BackupTransferMode = .export
    var phase: BackupTransferPhase = .password
    var password = ""
    var confirmation = ""
    var errorMessage: String?
    var recoveryURL: URL?
    var isBusy = false
    var isCommitting = false
    var prepared: PreparedBackup?
    var sourceURL: URL?
    @ObservationIgnored var dismiss: () -> Void = {}
    @ObservationIgnored var showProfiles: () -> Void = {}
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let profiles: PlusProfileController
    @ObservationIgnored private let email: DotTrickController
    @ObservationIgnored private let service: BackupService
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private let panelPresenter: (@MainActor (NSSavePanel) async -> NSApplication.ModalResponse)?

    init(profiles: PlusProfileController, email: DotTrickController,
         root: URL = ProfileCatalogStore.defaultFileURL().deletingLastPathComponent(),
         panelPresenter: (@MainActor (NSSavePanel) async -> NSApplication.ModalResponse)? = nil) {
        self.profiles = profiles; self.email = email; self.root = root
        self.panelPresenter = panelPresenter
        service = BackupService(root: root)
    }

    var canSubmitPassword: Bool {
        !isBusy && !profiles.isTransferring && (mode == .export ? password.count >= 8 && password == confirmation : !password.isEmpty && sourceURL != nil)
    }
    var replacesExistingData: Bool { !profiles.profiles.isEmpty || !email.sessions.isEmpty }
    var sessionSummary: String {
        if profiles.isRefreshing { return "Checking account sessions…" }
        let needsLogin = profiles.profiles.filter { $0.state == .needsLogin }.count
        let ready = profiles.profiles.filter { $0.state == .ready }.count
        let unchecked = profiles.profiles.count - needsLogin - ready
        var parts: [String] = []
        if needsLogin > 0 { parts.append("\(needsLogin) account\(needsLogin == 1 ? " needs" : "s need") sign-in.") }
        if unchecked > 0 { parts.append("\(unchecked) account\(unchecked == 1 ? " could" : "s could") not be checked. Refresh in Profiles.") }
        if parts.isEmpty { parts.append("Your account sessions are ready. Chrome may ask you to sign in separately.") }
        return parts.joined(separator: " ")
    }

    func begin(_ mode: BackupTransferMode) {
        guard !isBusy, !profiles.isTransferring else { return }
        cleanupPrepared()
        self.mode = mode; phase = .password; errorMessage = nil; recoveryURL = nil
        password = ""; confirmation = ""; sourceURL = nil
        if mode == .restore { chooseBackup() }
    }

    func chooseBackup() {
        guard !isBusy, !profiles.isTransferring else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose Backup"
        panel.message = "Choose the backup from your other Mac."
        isBusy = true
        operation = Task { @MainActor in
            defer { finishOperation() }
            let response = await present(panel)
            guard !Task.isCancelled else { return }
            guard response == .OK, let url = panel.url else { if sourceURL == nil { dismiss() }; return }
            cleanupPrepared(); sourceURL = url; phase = .password; errorMessage = nil
        }
    }

    func submitPassword() {
        guard canSubmitPassword else { return }
        if mode == .export { exportBackup() } else { unlockBackup() }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "CodexPlusBar-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).codexplusbarbackup"
        panel.prompt = "Export Backup"
        isBusy = true
        operation = Task { @MainActor in
            defer { finishOperation() }
            guard await present(panel) == .OK, !Task.isCancelled, let url = panel.url else { return }
            errorMessage = nil; phase = .working("Preparing your data…")
            do {
                try await pause()
                defer { resume(reload: false) }
                let manifest = await captureManifest()
                try Task.checkCancellation()
                phase = .working("Compressing and encrypting…")
                try await service.export(to: url, password: password, manifest: manifest)
                password = ""; confirmation = ""
                phase = .exported(url)
            } catch { handle(error) }
        }
    }

    private func unlockBackup() {
        guard let sourceURL else { return }
        isBusy = true; errorMessage = nil; phase = .working("Unlocking and checking backup…")
        operation = Task { @MainActor in
            do {
                prepared = try await service.prepare(from: sourceURL, password: password)
                phase = .preview
            } catch { handle(error) }
            finishOperation()
        }
    }

    func restoreBackup() {
        guard !isBusy, !profiles.isTransferring, let prepared else { return }
        isBusy = true; errorMessage = nil; phase = .working("Preparing to restore…")
        operation = Task { @MainActor in
            var committed = false
            var paused = false
            do {
                try await pause()
                paused = true
                if FileManager.default.fileExists(atPath: root.path) {
                    phase = .working("Saving a recovery backup…")
                    let recovery = try await service.recoveryURL()
                    try await service.export(to: recovery, password: password, manifest: await captureManifest())
                    recoveryURL = recovery
                }
                try Task.checkCancellation()
                isCommitting = true
                phase = .working("Restoring your profiles…")
                try await service.commit(prepared)
                committed = true
                self.prepared = nil
                try await BackupSessionBridge.finishRestore(root: root)
                password = ""; confirmation = ""
                resume(reload: true)
                phase = .restored(prepared.manifest.profileCount)
            } catch {
                if committed {
                    // Keep writers paused; startup can retry the durable receipt safely.
                    phase = .recoveryNeeded
                    errorMessage = "Your profiles are restored. Reopen CodexPlusBar to finish restoring sessions and settings."
                    password = ""; confirmation = ""
                } else {
                    if paused { resume(reload: false) }
                    handle(error)
                }
            }
            finishOperation()
        }
    }

    private func pause() async throws {
        guard !profiles.isTransferring else { throw BackupError.busy }
        email.isTransferring = true
        do {
            try await profiles.pauseForBackup()
            try await Task.detached { [root] in try BackupBrowserGuard.check(root: root) }.value
        } catch { resume(reload: false); throw error }
    }

    private func captureManifest() async -> BackupManifest {
        let values = profiles.profiles.map(\.profile)
        return BackupManifest(profileCount: values.count, preferences: BackupSessionBridge.preferences(),
                              cookies: await BackupSessionBridge.collectCookies(profiles: values))
    }

    private func resume(reload: Bool) {
        if reload { email.loadFromDisk() }
        email.isTransferring = false
        profiles.resumeAfterBackup(reload: reload)
    }

    func cancel() {
        guard !isCommitting else { return }
        if isBusy { operation?.cancel(); return }
        cleanupPrepared(); password = ""; confirmation = ""; dismiss()
    }

    private func cleanupPrepared() {
        if let prepared { Task { await service.discard(prepared) } }
        prepared = nil
    }

    private func finishOperation() {
        isBusy = false; isCommitting = false; operation = nil
    }

    private func handle(_ error: any Error) {
        phase = prepared == nil ? .password : .preview
        if error is CancellationError { errorMessage = "Cancelled. Your current data has been kept." }
        else { errorMessage = (error as? BackupError)?.localizedDescription ?? BackupError.storage.localizedDescription }
    }

    private func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        if let panelPresenter { return await panelPresenter(panel) }
        if let window { return await panel.beginSheetModal(for: window) }
        return await panel.begin()
    }
}
