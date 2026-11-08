import Foundation

/// The pending grants also serve as restart-safe retry receipts. They contain secrets
/// and use the same private-file discipline as the existing sign-in vaults.
struct AppSignInRepairStore: Sendable {
    let directory: URL
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent("Library/Application Support/CodexPlusBar/AppSignInRepairs")
    }
    private func url(_ profile: PlusProfile, _ destination: AppSignInDestination) -> URL {
        directory.appendingPathComponent("\(profile.id.uuidString)-\(destination.rawValue).json")
    }
    func load(_ profile: PlusProfile, _ destination: AppSignInDestination) throws -> CodexSignIn? {
        let file = url(profile, destination)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try CodexSignIn(data: Data(contentsOf: file)) }
        catch { throw AppSignInRepairError.storageFailed }
    }
    func save(_ signIn: CodexSignIn, profile: PlusProfile, destination: AppSignInDestination) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try OpenCodePrivateFile.write(signIn.data, to: url(profile, destination))
        } catch { throw AppSignInRepairError.storageFailed }
    }
    func remove(_ profile: PlusProfile, _ destination: AppSignInDestination) throws {
        let file = url(profile, destination)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

actor AppSignInRepairService: AppSignInRepairing {
    let authorizer: any AppSignInAuthorizing
    let installer: any AppSignInRepairInstalling
    let store: AppSignInRepairStore
    private var busy = false

    init(authorizer: any AppSignInAuthorizing = CodexBrowserAuthorization(),
         installer: any AppSignInRepairInstalling = AppSignInRepairInstaller(), store: AppSignInRepairStore = .init()) {
        self.authorizer = authorizer; self.installer = installer; self.store = store
    }

    func repair(profile: PlusProfile, openURL: @escaping @Sendable (URL) async throws -> Void,
                progress: @escaping @Sendable (AppSignInRepairProgress) async -> Void,
                completed: @escaping @Sendable (AppSignInRepairCompletion) async throws -> Void,
                isCurrent: @escaping @Sendable () async -> Bool) async throws {
        guard !busy else { throw CodexSignInError.busy }
        busy = true; defer { busy = false }
        var bound = profile
        var first: CodexSignIn?
        for destination in AppSignInDestination.allCases {
            try Task.checkCancellation()
            guard await isCurrent() else { throw AppSignInRepairError.changed }
            var pending = try store.load(profile, destination)
            // Old receipts belonging to a deliberately rebound profile are never installed.
            if let saved = pending, (try? saved.validateRepair(for: bound)) == nil {
                try store.remove(profile, destination); pending = nil
            }
            var attemptedLogin = false
            while true {
                if pending == nil {
                    await progress(.init(profileID: profile.id, destination: destination,
                        message: "\(destination == .desktop ? "1" : "2") of 2 · Sign in to \(destination.title) in Chrome."))
                    let fresh = try await authorizer.authorize(profile: bound, openURL: openURL)
                    try fresh.validateRepair(for: bound)
                    if let first, first.refreshToken == fresh.refreshToken {
                        try await authorizer.acknowledge(fresh, profile: profile)
                        throw AppSignInRepairError.sharedCredential
                    }
                    // Preserve a completed grant before noticing cancellation or subsequent errors.
                    try store.save(fresh, profile: profile, destination: destination)
                    pending = fresh; attemptedLogin = true
                }
                let signIn = pending!
                try signIn.validateRepair(for: bound)
                if let first, first.refreshToken == signIn.refreshToken {
                    try store.remove(profile, destination)
                    try await authorizer.acknowledge(signIn, profile: profile)
                    throw AppSignInRepairError.sharedCredential
                }
                try await authorizer.acknowledge(signIn, profile: profile)
                try Task.checkCancellation()
                guard await isCurrent() else { throw AppSignInRepairError.changed }
                await progress(.init(profileID: profile.id, destination: destination, message: "Updating \(destination.title)…"))
                do { try await installer.install(signIn, for: bound, destination: destination) }
                catch {
                    let rejected = (error as? CodexSignInError) == .unauthorized
                        || (error as? OpenCodeOpenAIVerificationError) == .reauthenticationRequired
                        || (error as? OpenCodeOpenAIVerificationError) == .unauthorized
                        || (error as? AppSignInRepairError) == .interruptedInstallation
                    if rejected, !attemptedLogin {
                        try store.remove(profile, destination); pending = nil; continue
                    }
                    throw error
                }
                guard await isCurrent() else { throw AppSignInRepairError.changed }
                try await completed(.init(destination: destination, identity: signIn.identity))
                if destination == .desktop {
                    first = signIn; bound.codexSignIn = signIn.identity
                }
                break
            }
        }
        // Keep receipts through partial failure; full success starts a fresh repair next time.
        for destination in AppSignInDestination.allCases { try store.remove(profile, destination) }
    }
}
