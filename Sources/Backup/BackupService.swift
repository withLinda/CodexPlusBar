import Darwin
import Foundation

struct PreparedBackup: Sendable, Identifiable {
    let id: UUID
    let directory: URL
    let manifest: BackupManifest
}

/// Owns staging and same-volume commits; all disk and compression work stays off the main actor.
actor BackupService {
    let root: URL
    private var preparations: Set<UUID> = []
    private let fm = FileManager.default
    static let receiptName = "BackupRestore.json"
    private static let maximumJSONBytes = 64 * 1_024 * 1_024
    static let includedRoots: Set<String> = ["profiles.json", "dot-trick-sessions.json", "DesktopSignIns", "OpenChamberSignIns", "ChromeProfiles"]

    init(root: URL = ProfileCatalogStore.defaultFileURL().deletingLastPathComponent()) {
        self.root = root
    }

    func export(to file: URL, password: String, manifest: BackupManifest) throws {
        let staging = try makeStaging()
        defer { try? fm.removeItem(at: staging) }
        let data = staging.appendingPathComponent("Data")
        try fm.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let files = fm.fileExists(atPath: root.path) ? try snapshotFiles() : []
        for path in files {
            try Task.checkCancellation()
            let from = root.appendingPathComponent(path), to = data.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let before = try from.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            try fm.copyItem(at: from, to: to)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
            let after = try from.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw BackupError.changed }
        }
        if !fm.fileExists(atPath: data.appendingPathComponent("profiles.json").path) {
            guard manifest.profileCount == 0 else { throw BackupError.invalidData }
            try Data("[]".utf8).write(to: data.appendingPathComponent("profiles.json"))
        }
        try validateData(data, manifest: manifest)
        try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))
        try BackupArchive.encode(directory: staging, to: file, password: password)
    }

    func prepare(from file: URL, password: String) throws -> PreparedBackup {
        let holder = try makeStaging()
        let directory = holder.appendingPathComponent("archive")
        do {
            try BackupArchive.decode(from: file, to: directory, password: password)
            let files = try BackupArchive.regularFiles(in: directory)
            guard files.allSatisfy({ $0.0 == "manifest.json" || $0.0.hasPrefix("Data/") }) else { throw BackupError.invalidArchive }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: readJSON(manifestURL, limit: 16 * 1_024 * 1_024))
            try validateData(directory.appendingPathComponent("Data"), manifest: manifest)
            let id = UUID()
            preparations.insert(id)
            return PreparedBackup(id: id, directory: directory, manifest: manifest)
        } catch {
            try? fm.removeItem(at: holder)
            if error is BackupError || error is CancellationError { throw error }
            throw BackupError.invalidData
        }
    }

    func discard(_ backup: PreparedBackup) {
        guard preparations.remove(backup.id) != nil else { return }
        try? fm.removeItem(at: backup.directory.deletingLastPathComponent())
    }

    /// Caller has quiesced app writers and, when replacing data, exported its recovery archive.
    func commit(_ backup: PreparedBackup) throws {
        guard preparations.contains(backup.id) else { throw BackupError.invalidArchive }
        let original = backup.directory.appendingPathComponent("Data")
        try validateData(original, manifest: backup.manifest)
        let data = backup.directory.deletingLastPathComponent().appendingPathComponent("install-\(UUID())")
        try fm.copyItem(at: original, to: data)
        defer { try? fm.removeItem(at: data) }
        let catalog = data.appendingPathComponent("profiles.json")
        let catalogData = try readJSON(catalog)
        let profiles = try JSONDecoder().decode([PlusProfile].self, from: catalogData)
        // Fresh native stores prevent precommit mutation of an existing installation's cookies.
        guard var encoded = try JSONSerialization.jsonObject(with: catalogData) as? [[String: Any]] else { throw BackupError.invalidData }
        var directoryRenames: [String: String] = [:]
        for index in encoded.indices {
            let old = profiles[index].webDataStoreID
            let new = UUID()
            directoryRenames[ChromeProfileStore.profileDirectoryName(for: old)] = ChromeProfileStore.profileDirectoryName(for: new)
            encoded[index]["webDataStoreID"] = new.uuidString
            let chrome = data.appendingPathComponent("ChromeProfiles")
            for (from, to) in [(ChromeProfileStore.profileDirectoryName(for: old), ChromeProfileStore.profileDirectoryName(for: new)), (old.uuidString, new.uuidString)] {
                let source = chrome.appendingPathComponent(from)
                if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: chrome.appendingPathComponent(to)) }
            }
        }
        try updateChromeProfileNames(in: data, renames: directoryRenames)
        try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]).write(to: catalog, options: .atomic)
        try writeJSON(backup.manifest, to: data.appendingPathComponent(Self.receiptName))
        try Task.checkCancellation()
        // One atomic commit point. A crash sees either old data or a complete new tree + receipt.
        if fm.fileExists(atPath: root.path) {
            guard renamex_np(data.path, root.path, UInt32(RENAME_SWAP)) == 0 else { throw BackupError.storage }
        } else {
            guard renamex_np(data.path, root.path, UInt32(RENAME_EXCL)) == 0 else { throw BackupError.storage }
        }
        preparations.remove(backup.id)
        try? fm.removeItem(at: backup.directory.deletingLastPathComponent())
    }

    func recoveryURL() throws -> URL {
        let directory = root.deletingLastPathComponent().appendingPathComponent("CodexPlusBar Backups")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return directory.appendingPathComponent("Before restore \(formatter.string(from: .now))-\(UUID().uuidString.prefix(6)).codexplusbarbackup")
    }

    private func makeStaging() throws -> URL {
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".CodexPlusBar-transfer-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return staging
    }

    private func updateChromeProfileNames(in data: URL, renames: [String: String]) throws {
        let file = data.appendingPathComponent("ChromeProfiles/Local State")
        guard fm.fileExists(atPath: file.path) else { return }
        guard var state = try JSONSerialization.jsonObject(with: readJSON(file)) as? [String: Any],
              var profile = state["profile"] as? [String: Any] else { return }
        if let cache = profile["info_cache"] as? [String: Any] {
            var next: [String: Any] = [:]
            for (key, value) in cache { next[renames[key] ?? key] = value }
            profile["info_cache"] = next
        }
        if let value = profile["last_used"] as? String { profile["last_used"] = renames[value] ?? value }
        if let values = profile["last_active_profiles"] as? [String] { profile["last_active_profiles"] = values.map { renames[$0] ?? $0 } }
        state["profile"] = profile
        try JSONSerialization.data(withJSONObject: state).write(to: file, options: .atomic)
    }

    private func snapshotFiles() throws -> [String] {
        // Traverse selected roots individually so unrelated runtime sockets/locks are not archived.
        var paths: [String] = []
        for name in Self.includedRoots.sorted() {
            let item = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: item.path) else { continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw BackupError.unsafePath }
            if values.isDirectory == true {
                try collect(item, prefix: name, paths: &paths)
            } else {
                guard values.isRegularFile == true else { throw BackupError.unsafePath }
                paths.append(name)
            }
        }
        return paths.sorted()
    }

    private func collect(_ directory: URL, prefix: String, paths: inout [String]) throws {
        for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) {
            try Task.checkCancellation()
            let path = prefix + "/" + item.lastPathComponent
            if Self.isDisposable(path) { continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw BackupError.unsafePath }
            if values.isDirectory == true { try collect(item, prefix: path, paths: &paths) }
            else {
                guard values.isRegularFile == true else { throw BackupError.unsafePath }
                paths.append(path)
            }
            guard paths.count <= BackupArchive.maximumEntries else { throw BackupError.tooLarge }
        }
    }

    static func isDisposable(_ path: String) -> Bool {
        guard path.hasPrefix("ChromeProfiles/") else { return false }
        let names: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "Media Cache", "CacheStorage", "ScriptCache", "component_crx_cache", "extensions_crx_cache", "SODA", "SODALanguagePacks", "optimization_guide_model_store", "WasmTtsEngine", "GraphiteDawnCache", "GPUPersistentCache", "Crashpad", "BrowserMetrics", "SingletonLock", "SingletonCookie", "SingletonSocket", "DevToolsActivePort", "LOCK", "LOG", "LOG.old", ".DS_Store"]
        return path.split(separator: "/").contains { names.contains(String($0)) }
    }

    private func validateData(_ data: URL, manifest: BackupManifest) throws {
        let files = try BackupArchive.regularFiles(in: data)
        guard files.allSatisfy({ Self.includedRoots.contains(String($0.0.split(separator: "/")[0])) }) else { throw BackupError.invalidArchive }
        let catalog = data.appendingPathComponent("profiles.json")
        let profiles = try JSONDecoder().decode([PlusProfile].self, from: readJSON(catalog))
        try manifest.validate(profiles: profiles)
        let email = data.appendingPathComponent("dot-trick-sessions.json")
        if fm.fileExists(atPath: email.path) { _ = try JSONDecoder().decode([DotTrickSession].self, from: readJSON(email)) }
        let chrome = data.appendingPathComponent("ChromeProfiles/Local State")
        if fm.fileExists(atPath: chrome.path) { _ = try JSONSerialization.jsonObject(with: readJSON(chrome)) }
        for (path, size) in files where path.hasPrefix("DesktopSignIns/") || path.hasPrefix("OpenChamberSignIns/") {
            guard size <= Self.maximumJSONBytes, path.hasSuffix(".json") else { throw BackupError.invalidData }
            _ = try JSONSerialization.jsonObject(with: readJSON(data.appendingPathComponent(path)), options: [.fragmentsAllowed])
        }
    }

    private func readJSON(_ url: URL, limit: Int = maximumJSONBytes) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { throw BackupError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw BackupError.tooLarge }
        return data
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let bytes = try JSONEncoder().encode(value)
        // An export must satisfy the same manifest limit as a future restore.
        guard bytes.count <= 16 * 1_024 * 1_024 else { throw BackupError.tooLarge }
        try bytes.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
