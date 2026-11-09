import CryptoKit
import Darwin
import Foundation

struct CloudSyncPaths: Sendable {
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexPlusBar CloudSync")) {
        // Foundation standardization/resolvingSymlinks abbreviates /private/var back to
        // the /var symlink. Expand only this macOS system alias, never caller symlinks.
        if root.isFileURL, root.path.hasPrefix("/var/") {
            self.root = URL(fileURLWithPath: "/private" + root.path, isDirectory: true)
        } else {
            self.root = root
        }
    }

    var deviceFile: URL { root.appendingPathComponent("device.json") }

    func partition(for owner: CloudOwner) -> URL {
        root.appendingPathComponent("owners").appendingPathComponent(Self.ownerDigest(owner))
    }

    /// Length-prefixed UTF-8 avoids delimiter ambiguity; environment/container are part of identity.
    static func ownerDigest(_ owner: CloudOwner) -> String {
        var bytes = Data()
        for value in [owner.container, owner.environment.rawValue, owner.userRecordName] {
            let field = Data(value.precomposedStringWithCanonicalMapping.utf8)
            bytes.append(contentsOf: "\(field.count):".utf8)
            bytes.append(field)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudSyncPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var paused = false
    var includeSavedSessions = true
}

struct CloudSyncDeviceState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let deviceID: UUID
    var preferences = CloudSyncPreferences()
}

/// Fault injection at real disk operation boundaries. Production always uses the default no-op hook.
struct CloudJournalIO: Sendable {
    enum Operation: Sendable { case write, fileSync, rename, directorySync, recoverySync, directoryLinkSync }
    let before: @Sendable (Operation, String) throws -> Void

    init(before: @escaping @Sendable (Operation, String) throws -> Void = { _, _ in }) {
        self.before = before
    }
}

/// Descriptor-relative access never follows a link, including an intermediate directory.
enum CloudPrivateFiles {
    static func systemError(operation: String = #function, line: Int = #line) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO,
                   userInfo: [NSLocalizedFailureReasonErrorKey: "Cloud sync storage: \(operation), line \(line)"])
    }

    static func openRoot(_ root: URL, io: CloudJournalIO, create: Bool = true, requirePrivate: Bool = true) throws -> Int32 {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"),
              !root.pathComponents.contains(where: { $0.caseInsensitiveCompare("CodexPlusBar") == .orderedSame }),
              root.pathComponents.count > 1 else {
            throw CloudJournalError.unsafePath
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        do {
            let components = root.pathComponents.dropFirst()
            for (index, component) in components.enumerated() {
                let next = try directory(component, in: descriptor,
                                         requirePrivate: requirePrivate && index == components.count - 1, io: io, create: create)
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    static func directory(_ name: String, in parent: Int32, requirePrivate: Bool = true,
                          io: CloudJournalIO, create: Bool = true) throws -> Int32 {
        try validateName(name)
        var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, create {
            if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw systemError() }
            descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw systemError() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw systemError() }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw CloudJournalError.unsafePath }
            if requirePrivate {
                guard info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { throw CloudJournalError.unsafePath }
            }
            // A visible directory may survive a failed mkdir-parent fsync from an
            // earlier process. Confirm every link on every walk, including ancestors,
            // before any journal operation can report success. Syncing only this
            // directory would not persist its name in its parent.
            if create {
                try io.before(.directoryLinkSync, name)
                guard fsync(parent) == 0 else { throw systemError() }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    static func lock(in directory: Int32) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var descriptor = openat(directory, ".lock", flags)
        if descriptor < 0, errno == ENOENT {
            // On APFS simultaneous O_CREAT opens can return ENOENT even with a live
            // parent. Exclusive creation + reopening the winner avoids that race.
            descriptor = openat(directory, ".lock", flags | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0, errno == EEXIST { descriptor = openat(directory, ".lock", flags) }
        }
        guard descriptor >= 0 else { throw systemError() }
        do {
            _ = try validateFile(descriptor)
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw systemError() }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    static func openFile(_ name: String, in directory: Int32, requirePrivate: Bool = true) throws -> Int32? {
        try validateName(name)
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw systemError() }
        do {
            _ = try validateFile(descriptor, requirePrivate: requirePrivate)
            return descriptor
        } catch { close(descriptor); throw error }
    }

    static func read(_ name: String, in directory: Int32, limit: Int, requirePrivate: Bool = true) throws -> Data? {
        guard let descriptor = try openFile(name, in: directory, requirePrivate: requirePrivate) else { return nil }
        defer { close(descriptor) }
        let info = try validateFile(descriptor, requirePrivate: requirePrivate)
        guard info.st_size >= 0, info.st_size <= limit else { throw CloudJournalError.tooLarge }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit - bytes.count + 1))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw systemError() }
            if count == 0 { break }
            guard count <= limit - bytes.count else { throw CloudJournalError.tooLarge }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count == info.st_size else { throw CloudJournalError.corruptState }
        return bytes
    }

    static func replace(_ name: String, bytes: Data, in directory: Int32, io: CloudJournalIO) throws {
        try validateName(name)
        try validateTarget(name, in: directory)
        let temporary = ".staged-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw systemError() }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try io.before(.write, name)
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), min(buffer.count - offset, 65_536))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemError() }
                offset += count
            }
        }
        try io.before(.fileSync, name)
        guard fsync(descriptor) == 0 else { throw systemError() }
        try validateTarget(name, in: directory)
        try io.before(.rename, name)
        guard renameat(directory, temporary, directory, name) == 0 else { throw systemError() }
        do {
            try io.before(.directorySync, name)
            guard fsync(directory) == 0 else { throw systemError() }
        } catch { throw CloudJournalError.commitUncertain(name) }
    }

    static func synchronize(_ name: String, in directory: Int32) throws {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        defer { close(descriptor) }
        _ = try validateFile(descriptor)
        guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw systemError() }
    }

    static func remove(_ name: String, in directory: Int32) throws {
        try validateTarget(name, in: directory)
        guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw systemError() }
        guard fsync(directory) == 0 else { throw systemError() }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw CloudJournalError.unsafePath
        }
    }

    private static func validateFile(_ descriptor: Int32, requirePrivate: Bool = true) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError() }
        try validate(info, requirePrivate: requirePrivate)
        return info
    }

    private static func validate(_ info: stat, requirePrivate: Bool = true) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), !requirePrivate || info.st_mode & 0o7777 == 0o600 else { throw CloudJournalError.unsafePath }
    }

    private static func validateTarget(_ name: String, in directory: Int32) throws {
        try validateName(name)
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw systemError()
        }
        try validate(info)
    }
}
