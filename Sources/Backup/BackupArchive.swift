import AppleArchive
import CryptoKit
import Darwin
import Foundation
import System

enum BackupError: LocalizedError, Equatable {
    case invalidArchive, unlockFailed, unsupportedVersion, unsafePath, tooLarge, changed, busy, storage, password, invalidData

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "This is not a complete CodexPlusBar backup. Choose another file."
        case .unlockFailed: "The password is incorrect or the backup is damaged. Try again."
        case .unsupportedVersion: "This backup needs a newer CodexPlusBar. Update the app, then try again."
        case .unsafePath: "This backup contains unsupported files and cannot be restored."
        case .tooLarge: "This backup exceeds the supported size. Check the source data and available disk space."
        case .changed: "Data changed during the backup. Close the app’s Chrome windows and try again."
        case .busy: "Wait for the current account action to finish, then try again."
        case .storage: "The backup could not be saved. Check available disk space and folder access."
        case .password: "Use a backup password with at least 8 characters."
        case .invalidData: "The saved data is incomplete or unreadable. Your current data has been kept."
        }
    }
}

/// AEA provides streaming compression, a password KDF and authenticated encryption.
/// Only regular files are encoded. Extraction never delegates paths or permissions to an archive.
enum BackupArchive {
    static let maximumBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024
    static let maximumEntries = 100_000
    private static let bufferSize = 1_048_576
    private static let identifier = Data("com.linda.CodexPlusBar.backup/1".utf8)

    static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/") &&
        !path.contains("\\") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func encode(directory: URL, to destination: URL, password: String) throws {
        guard password.count >= 8 else { throw BackupError.password }
        let files = try regularFiles(in: directory)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try ArchiveByteStream.withFileStream(path: FilePath(temporary.path), mode: .writeOnly,
                                            options: [.create, .exclusiveCreate], permissions: .init(rawValue: 0o600)) { file in
            let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
            context.authData = identifier
            try context.setPassword(archivePassword(password))
            guard let encrypted = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context, threadCount: 1) else {
                throw BackupError.storage
            }
            try closing(encrypted) {
                guard let stream = ArchiveStream.encodeStream(writingTo: encrypted, threadCount: 1) else { throw BackupError.storage }
                do {
                    for (path, size) in files {
                        try Task.checkCancellation()
                        let header = ArchiveHeader()
                        header.append(.uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
                        header.append(.string(key: .init("PAT"), value: path))
                        header.append(.blob(key: .init("DAT"), size: size))
                        try stream.writeHeader(header)
                        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(path))
                        defer { try? handle.close() }
                        var remaining = size
                        while remaining > 0 {
                            try Task.checkCancellation()
                            let bytes = try handle.read(upToCount: Int(min(remaining, UInt64(bufferSize)))) ?? Data()
                            guard !bytes.isEmpty else { throw BackupError.changed }
                            try bytes.withUnsafeBytes { try stream.writeBlob(key: .init("DAT"), from: $0) }
                            remaining -= UInt64(bytes.count)
                        }
                        guard try handle.read(upToCount: 1)?.isEmpty != false else { throw BackupError.changed }
                    }
                    try stream.close()
                } catch { try? stream.close(); throw error }
            }
        }
        try Task.checkCancellation()
        // POSIX rename atomically replaces an existing successful export only after finalization.
        guard rename(temporary.path, destination.path) == 0 else { throw BackupError.storage }
    }

    static func decode(from source: URL, to destination: URL, password: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw BackupError.storage }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try ArchiveByteStream.withFileStream(path: FilePath(source.path), mode: .readOnly, options: [], permissions: []) { file in
                guard let context = ArchiveEncryptionContext(from: file),
                      context.profile == .hkdf_sha256_aesctr_hmac__scrypt__none,
                      context.authData == identifier else { throw BackupError.invalidArchive }
                try context.setPassword(archivePassword(password))
                guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context, threadCount: 1) else {
                    throw BackupError.unlockFailed
                }
                try closing(decrypted) {
                    guard let stream = ArchiveStream.decodeStream(readingFrom: decrypted, threadCount: 1) else { throw BackupError.unlockFailed }
                    do {
                        var paths: Set<String> = []
                        var spellings: [String: String] = [:]
                        var directories: Set<String> = []
                        var total: UInt64 = 0
                        while let header = try stream.readHeader() {
                            try Task.checkCancellation()
                            guard header.entryType == .regularFile, let path = header.entryPath?.string,
                                  isSafePath(path), header.count == 3,
                                  case let .blob(_, size, _)? = header.field(forKey: .init("DAT")),
                                  paths.insert(canonicalPath(path)).inserted else { throw BackupError.unsafePath }
                            guard paths.count <= maximumEntries, size <= maximumBytes - total else { throw BackupError.tooLarge }
                            try validatePathSpelling(path, spellings: &spellings)
                            total += size
                            let target = destination.appendingPathComponent(path)
                            try makePrivateParents(path: path, under: destination, created: &directories)
                            // The filesystem is the final authority on name equivalence.
                            let descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                            guard descriptor >= 0 else { throw errno == EEXIST ? BackupError.unsafePath : BackupError.storage }
                            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                            defer { try? output.close() }
                            var remaining = size
                            while remaining > 0 {
                                try Task.checkCancellation()
                                var bytes = Data(count: Int(min(remaining, UInt64(bufferSize))))
                                try bytes.withUnsafeMutableBytes { try stream.readBlob(key: .init("DAT"), into: $0) }
                                try output.write(contentsOf: bytes)
                                remaining -= UInt64(bytes.count)
                            }
                            try output.synchronize()
                        }
                        try stream.close()
                        // Drain to the authenticated end; trailing plaintext is not part of our format.
                        var tail = [UInt8](repeating: 0, count: 1)
                        let count = try tail.withUnsafeMutableBytes { try decrypted.read(into: $0) }
                        guard count == 0 else { throw BackupError.invalidArchive }
                    } catch { try? stream.close(); throw error }
                }
                // AEA EOF can leave an unauthenticated suffix unread. Its authenticated
                // container size includes padding; compare against the same open file.
                guard context.containerSize > 0,
                      try file.seek(toOffset: 0, relativeTo: .end) == Int64(context.containerSize) else {
                    throw BackupError.invalidArchive
                }
            }
        } catch {
            try? fm.removeItem(at: destination)
            if error is CancellationError || error is BackupError { throw error }
            throw BackupError.unlockFailed
        }
    }

    static func canonicalPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    // AEA enforces a >=20-byte password. Prehash arbitrary UTF-8 input to a fixed
    // 64-byte representation; AEA still applies its salted, memory-hard scrypt KDF.
    private static func archivePassword(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func regularFiles(in directory: URL) throws -> [(String, UInt64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard try directory.resourceValues(forKeys: keys).isSymbolicLink != true else { throw BackupError.unsafePath }
        let directory = directory.resolvingSymlinksInPath()
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
            enumerationFailed = true; return false
        }) else { throw BackupError.storage }
        var result: [(String, UInt64)] = [], paths: Set<String> = [], total: UInt64 = 0
        var spellings: [String: String] = [:]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw BackupError.unsafePath }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw BackupError.unsafePath }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 == 1 else { throw BackupError.unsafePath }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(directory.path + "/") else { throw BackupError.unsafePath }
            let path = String(resolved.dropFirst(directory.path.count + 1))
            guard isSafePath(path), paths.insert(canonicalPath(path)).inserted else { throw BackupError.unsafePath }
            try validatePathSpelling(path, spellings: &spellings)
            let size = UInt64(values.fileSize ?? 0)
            guard result.count < maximumEntries, size <= maximumBytes - total else { throw BackupError.tooLarge }
            total += size
            result.append((path, size))
        }
        guard !enumerationFailed else { throw BackupError.storage }
        return result.sorted { $0.0 < $1.0 }
    }

    private static func validatePathSpelling(_ path: String, spellings: inout [String: String]) throws {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += (prefix.isEmpty ? "" : "/") + component
            let key = canonicalPath(prefix)
            if let previous = spellings[key], !previous.utf8.elementsEqual(prefix.utf8) { throw BackupError.unsafePath }
            spellings[key] = prefix
            guard spellings.count <= maximumEntries else { throw BackupError.tooLarge }
        }
    }

    private static func makePrivateParents(path: String, under root: URL, created: inout Set<String>) throws {
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix += (prefix.isEmpty ? "" : "/") + component
            if created.insert(prefix).inserted {
                guard mkdir(root.appendingPathComponent(prefix).path, 0o700) == 0 else {
                    throw errno == EEXIST ? BackupError.unsafePath : BackupError.storage
                }
            }
        }
    }

    private static func closing<T>(_ stream: ArchiveByteStream, _ body: () throws -> T) throws -> T {
        do { let result = try body(); try stream.close(); return result }
        catch { try? stream.close(); throw error }
    }
}
