import Foundation

struct ChromeProfileStore {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL = ChromeProfileStore.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func profileDirectory(for profile: PlusProfile) -> URL {
        rootDirectory.appendingPathComponent(profile.webDataStoreID.uuidString, isDirectory: true)
    }

    func ensureProfileDirectory(for profile: PlusProfile) throws -> URL {
        let directory = profileDirectory(for: profile)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func hasProfileDirectory(for profile: PlusProfile) -> Bool {
        fileManager.fileExists(atPath: profileDirectory(for: profile).path)
    }

    func removeProfileDirectory(for profile: PlusProfile) throws {
        let directory = profileDirectory(for: profile)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        try fileManager.removeItem(at: directory)
    }

    static func defaultRootDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )

        return base
            .appendingPathComponent("CodexPlusBar", isDirectory: true)
            .appendingPathComponent("ChromeProfiles", isDirectory: true)
    }
}
