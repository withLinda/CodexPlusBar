import Foundation

/// The on-disk layout used by the Chrome helper.
///
/// Chrome treats `--user-data-dir` as an installation-wide directory.  The old
/// implementation used one of those directories for every saved account.  That
/// made Chrome copy its component downloads and extensions once per account.
/// We now use one user-data directory and one named Chrome profile per account.
struct ChromeProfileStore {
    private enum MigrationError: Error {
        case couldNotPreserveLocalState(URL)
    }

    struct MaintenanceReport: Equatable, Sendable {
        let migratedProfileCount: Int
        let removedOrphanCount: Int
        let removedDisposableItemCount: Int
    }

    let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL = ChromeProfileStore.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// The directory passed to Chrome as `--user-data-dir`.
    var userDataDirectory: URL {
        rootDirectory
    }

    /// The Chrome profile directory for a saved account.
    ///
    /// Keep this name independent from Chrome's built-in `Default`/`Profile 1`
    /// names.  The UUID is the long-lived identity already used by the app's
    /// native cookie store, so changing a profile label cannot move its data.
    func profileDirectory(for profile: PlusProfile) -> URL {
        rootDirectory.appendingPathComponent(
            profileDirectoryName(for: profile),
            isDirectory: true
        )
    }

    func profileDirectoryName(for profile: PlusProfile) -> String {
        Self.profileDirectoryName(for: profile.webDataStoreID)
    }

    func ensureProfileDirectory(for profile: PlusProfile) throws -> URL {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let directory = profileDirectory(for: profile)
        if fileManager.fileExists(atPath: directory.path) {
            // A previous migration can move `Default` successfully and then
            // stop before removing the old wrapper.  Let the migration helper
            // remove that wrapper when it no longer contains account data.
            try migrateLegacyProfileDirectoryIfNeeded(for: profile, to: directory)
            return directory
        }

        try migrateLegacyProfileDirectoryIfNeeded(for: profile, to: directory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func hasProfileDirectory(for profile: PlusProfile) -> Bool {
        fileManager.fileExists(atPath: profileDirectory(for: profile).path)
            || fileManager.fileExists(atPath: legacyProfileDirectory(for: profile).path)
    }

    /// Removes both the current and pre-migration locations for one account.
    /// Callers must close Chrome first because these directories contain cookies
    /// and password/passkey databases.
    func removeProfileDirectory(for profile: PlusProfile) throws {
        let currentDirectory = profileDirectory(for: profile)
        if fileManager.fileExists(atPath: currentDirectory.path) {
            try fileManager.removeItem(at: currentDirectory)
        }

        let legacyDirectory = legacyProfileDirectory(for: profile)
        if fileManager.fileExists(atPath: legacyDirectory.path) {
            try fileManager.removeItem(at: legacyDirectory)
        }

        try removeProfileMetadata(for: profile)
    }

    /// Migrates old per-account Chrome roots and removes only data that is
    /// disposable for this app.
    ///
    /// This operation is deliberately conservative when the catalog is empty:
    /// an empty catalog can mean that `profiles.json` could not be read, and it
    /// must never turn a read error into account-data deletion.  The app calls
    /// this once during startup, while no app-owned Chrome session is open.
    @discardableResult
    func migrateAndPrune(profiles: [PlusProfile]) throws -> MaintenanceReport {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        guard profiles.isEmpty == false else {
            return MaintenanceReport(
                migratedProfileCount: 0,
                removedOrphanCount: 0,
                removedDisposableItemCount: 0
            )
        }

        var migratedProfileCount = 0
        var removedDisposableItemCount = 0
        let profileIDs = Set(profiles.map(\.webDataStoreID))

        for profile in profiles {
            let legacyDirectory = legacyProfileDirectory(for: profile)
            let hadLegacyDirectory = fileManager.fileExists(atPath: legacyDirectory.path)
            _ = try ensureProfileDirectory(for: profile)
            if hadLegacyDirectory,
               fileManager.fileExists(atPath: legacyDirectory.path) == false {
                migratedProfileCount += 1
            }

            removedDisposableItemCount += try pruneDisposableData(
                in: profileDirectory(for: profile)
            )
        }

        removedDisposableItemCount += try pruneSharedDisposableData()

        var removedOrphanCount = 0
        for child in try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard let legacyID = UUID(uuidString: child.lastPathComponent),
                  profileIDs.contains(legacyID) == false,
                  isDirectory(child)
            else {
                continue
            }

            // A UUID-named child is the old layout.  It is safe to remove only
            // when it is no longer present in the saved profile catalog.
            try fileManager.removeItem(at: child)
            removedOrphanCount += 1
        }

        return MaintenanceReport(
            migratedProfileCount: migratedProfileCount,
            removedOrphanCount: removedOrphanCount,
            removedDisposableItemCount: removedDisposableItemCount
        )
    }

    /// Removes generated extensions and caches from one named profile while
    /// retaining cookies, normal and protected preferences, passwords,
    /// passkeys, bookmarks, web-app metadata, and website storage. Chrome must
    /// not be using the profile at this point.
    @discardableResult
    func pruneDisposableData(in profileDirectory: URL) throws -> Int {
        guard isDescendant(profileDirectory, of: rootDirectory) else {
            return 0
        }

        var removedCount = 0
        for name in Self.disposableProfileDirectoryNames {
            let item = profileDirectory.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: item.path) else {
                continue
            }

            try fileManager.removeItem(at: item)
            removedCount += 1
        }

        removedCount += removeDeletedExtensionThemePreference(
            in: profileDirectory
        )

        return removedCount
    }

    /// Removes installation-wide downloaded components.  Sharing one root
    /// already prevents 35 copies; pruning these after Chrome exits also keeps
    /// the helper from retaining stale speech/model downloads forever.
    @discardableResult
    func pruneSharedDisposableData() throws -> Int {
        var removedCount = 0
        for name in Self.disposableRootDirectoryNames {
            let item = rootDirectory.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: item.path) else {
                continue
            }

            try fileManager.removeItem(at: item)
            removedCount += 1
        }

        return removedCount
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

    private func legacyProfileDirectory(for profile: PlusProfile) -> URL {
        rootDirectory.appendingPathComponent(
            profile.webDataStoreID.uuidString,
            isDirectory: true
        )
    }

    private func migrateLegacyProfileDirectoryIfNeeded(
        for profile: PlusProfile,
        to destination: URL
    ) throws {
        let legacyDirectory = legacyProfileDirectory(for: profile)
        guard fileManager.fileExists(atPath: legacyDirectory.path) else {
            return
        }

        let legacyDefaultDirectory = legacyDirectory.appendingPathComponent(
            "Default",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: legacyDefaultDirectory.path) else {
            // The old root has no account data left.  Do not carry its copied
            // component caches into the new layout.
            try fileManager.removeItem(at: legacyDirectory)
            return
        }

        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        // The no-`Default` case was removed above. If both the destination and
        // a legacy `Default` still exist, keep both rather than overwriting
        // either account copy; that is an unresolved manual-recovery case.
        if fileManager.fileExists(atPath: destination.path) {
            return
        }

        do {
            try fileManager.moveItem(at: legacyDefaultDirectory, to: destination)
            let localStateSource = legacyDirectory.appendingPathComponent(
                "Local State",
                isDirectory: false
            )
            guard mergeLegacyLocalState(
                from: localStateSource,
                profileDirectoryName: profileDirectoryName(for: profile)
            ) else {
                throw MigrationError.couldNotPreserveLocalState(localStateSource)
            }

            // Everything outside `Default` belongs to the old user-data root,
            // not to the account's cookies/passwords.  Remove it only after the
            // account directory has moved successfully.
            try fileManager.removeItem(at: legacyDirectory)
        } catch {
            // Moving a directory on the same volume is atomic, but a malformed
            // Local State file or a permissions error can still happen.  Put
            // the account directory back so a failed upgrade never strands the
            // user's cookies.
            if fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: legacyDefaultDirectory.path) == false {
                try? fileManager.moveItem(at: destination, to: legacyDefaultDirectory)
            }
            throw error
        }
    }

    private func mergeLegacyLocalState(
        from source: URL,
        profileDirectoryName: String
    ) -> Bool {
        guard fileManager.fileExists(atPath: source.path) else {
            return true
        }

        guard let sourceData = try? Data(contentsOf: source),
              var legacyState = try? JSONSerialization.jsonObject(
                  with: sourceData,
                  options: [.fragmentsAllowed]
              ) as? [String: Any]
        else {
            return false
        }

        let destination = rootDirectory.appendingPathComponent(
            "Local State",
            isDirectory: false
        )

        if fileManager.fileExists(atPath: destination.path) == false {
            renameLegacyDefaultProfile(
                in: &legacyState,
                to: profileDirectoryName
            )
            return writeJSON(legacyState, to: destination)
        }

        guard let destinationData = try? Data(contentsOf: destination),
              var currentState = try? JSONSerialization.jsonObject(
                  with: destinationData,
                  options: [.fragmentsAllowed]
              ) as? [String: Any]
        else {
            return false
        }

        mergeProfileInfo(
            from: legacyState,
            into: &currentState,
            profileDirectoryName: profileDirectoryName
        )
        if currentState["os_crypt"] == nil,
           let legacyOSCrypt = legacyState["os_crypt"] {
            currentState["os_crypt"] = legacyOSCrypt
        }
        return writeJSON(currentState, to: destination)
    }

    private func renameLegacyDefaultProfile(
        in state: inout [String: Any],
        to profileDirectoryName: String
    ) {
        guard var profile = state["profile"] as? [String: Any] else {
            return
        }

        if var infoCache = profile["info_cache"] as? [String: Any],
           let defaultInfo = infoCache.removeValue(forKey: "Default") {
            infoCache[profileDirectoryName] = defaultInfo
            profile["info_cache"] = infoCache
        }
        if var profilesOrder = profile["profiles_order"] as? [String] {
            profilesOrder = profilesOrder.map {
                $0 == "Default" ? profileDirectoryName : $0
            }
            profile["profiles_order"] = profilesOrder
        }
        state["profile"] = profile
    }

    private func mergeProfileInfo(
        from legacyState: [String: Any],
        into currentState: inout [String: Any],
        profileDirectoryName: String
    ) {
        guard let legacyProfile = legacyState["profile"] as? [String: Any],
              let legacyInfoCache = legacyProfile["info_cache"] as? [String: Any],
              let defaultInfo = legacyInfoCache["Default"]
        else {
            return
        }

        var currentProfile = currentState["profile"] as? [String: Any] ?? [:]
        var currentInfoCache = currentProfile["info_cache"] as? [String: Any] ?? [:]
        if currentInfoCache[profileDirectoryName] == nil {
            currentInfoCache[profileDirectoryName] = defaultInfo
        }
        currentProfile["info_cache"] = currentInfoCache

        var currentOrder = currentProfile["profiles_order"] as? [String] ?? []
        if currentOrder.contains(profileDirectoryName) == false {
            currentOrder.append(profileDirectoryName)
        }
        currentProfile["profiles_order"] = currentOrder
        currentState["profile"] = currentProfile
    }

    private func writeJSON(_ object: [String: Any], to destination: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.withoutEscapingSlashes]
              )
        else {
            return false
        }

        do {
            try data.write(to: destination, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func removeProfileMetadata(for profile: PlusProfile) throws {
        let localStateURL = rootDirectory.appendingPathComponent(
            "Local State",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: localStateURL.path),
              let data = try? Data(contentsOf: localStateURL),
              var state = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ) as? [String: Any],
              var profileState = state["profile"] as? [String: Any]
        else {
            return
        }

        let name = profileDirectoryName(for: profile)
        if var infoCache = profileState["info_cache"] as? [String: Any] {
            infoCache.removeValue(forKey: name)
            profileState["info_cache"] = infoCache
        }
        if var order = profileState["profiles_order"] as? [String] {
            order.removeAll { $0 == name }
            profileState["profiles_order"] = order
        }
        state["profile"] = profileState

        guard JSONSerialization.isValidJSONObject(state),
              let updatedData = try? JSONSerialization.data(
                  withJSONObject: state,
                  options: [.withoutEscapingSlashes]
              )
        else {
            return
        }
        try updatedData.write(to: localStateURL, options: [.atomic])
    }

    /// Chrome stores an absolute path to the selected extension theme in
    /// `Preferences`. Once extension packages are removed, that path points to
    /// the old per-account root and Chrome logs an error on every launch. Keep
    /// every other preference and only return the helper profile to its default
    /// theme.
    private func removeDeletedExtensionThemePreference(
        in profileDirectory: URL
    ) -> Int {
        let preferencesURL = profileDirectory.appendingPathComponent(
            "Preferences",
            isDirectory: false
        )
        guard let data = try? Data(contentsOf: preferencesURL),
              var preferences = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ) as? [String: Any],
              var extensions = preferences["extensions"] as? [String: Any],
              extensions.removeValue(forKey: "theme") != nil
        else {
            return 0
        }

        preferences["extensions"] = extensions
        guard JSONSerialization.isValidJSONObject(preferences),
              let updatedData = try? JSONSerialization.data(
                  withJSONObject: preferences,
                  options: [.withoutEscapingSlashes]
              ),
              (try? updatedData.write(to: preferencesURL, options: [.atomic])) != nil
        else {
            return 0
        }

        return 1
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private static func profileDirectoryName(for identifier: UUID) -> String {
        "Profile-\(identifier.uuidString)"
    }

    // These directories/files are generated browsing state or extension/cache
    // data. Cookies, Preferences, Secure Preferences, Login Data,
    // passkey_enclave_state, Bookmarks, Web Applications, Local Storage,
    // IndexedDB, Web Data, and Sync Data are deliberately not in this list
    // because they can hold login credentials, Google account state, passkeys,
    // or records that refer to other retained data.
    private static let disposableProfileDirectoryNames: [String] = [
        "Extensions",
        "Extension State",
        "Extension Cookies",
        "Extension Rules",
        "Extension Scripts",
        "Local Extension Settings",
        "Sync Extension Settings",
        "Managed Extension Settings",
        "Storage/ext",
        "Cache",
        "Code Cache",
        "GPUCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache",
        "Media Cache",
        "Service Worker/CacheStorage",
        "Service Worker/ScriptCache",
        "blob_storage",
        "History",
        "History-journal",
        "Favicons",
        "Favicons-journal",
        "Top Sites",
        "Top Sites-journal",
        "Shortcuts",
        "Shortcuts-journal",
        "Network Action Predictor",
        "Network Action Predictor-journal",
        "Sessions",
        "GCM Store",
        "Shared Dictionary",
        "Search Logos",
        "DataSharing",
        "Collaboration",
        "LOCK",
        "LOG",
        "LOG.old",
    ]

    private static let disposableRootDirectoryNames: [String] = [
        "component_crx_cache",
        "extensions_crx_cache",
        "SODA",
        "SODALanguagePacks",
        "optimization_guide_model_store",
        "WasmTtsEngine",
        "OnDeviceHeadSuggestModel",
        "GraphiteDawnCache",
        "GPUPersistentCache",
        "OptimizationHints",
        "BrowserMetrics-spare.pma",
    ]
}
