import Foundation
import AppleArchive
import CryptoKit
import System
import Testing
@testable import CodexPlusBar

struct BackupArchiveTests {
    @Test func unicodeAndParentDirectoryAliasesCannotOverwriteExtractedData() throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, pair) in [("SS", "ß"), ("Σ", "ς"), ("Parent/first", "parent/second"),
                              ("SS/first", "ß/second")].enumerated() {
            let file = root.appendingPathComponent("collision-\(index)")
            try maliciousArchive(file: file, entries: [("Data/\(pair.0)", .regularFile, 0), ("Data/\(pair.1)", .regularFile, 0)])
            let output = root.appendingPathComponent("output-\(index)")
            #expect(throws: BackupError.unsafePath) { try BackupArchive.decode(from: file, to: output, password: "test password") }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func appendedBytesAndConcatenatedContainersAreRejected() throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive")
        try maliciousArchive(file: file, entries: [("manifest.json", .regularFile, 0)])
        let original = try Data(contentsOf: file)
        for (index, suffix) in [Data("UNAUTHENTICATED TRAILING BYTES".utf8), original].enumerated() {
            try (original + suffix).write(to: file)
            let output = root.appendingPathComponent("output-\(index)")
            #expect(throws: BackupError.invalidArchive) { try BackupArchive.decode(from: file, to: output, password: "test password") }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func authenticatedMaliciousEntriesAreRejectedBeforeWritingOutsideStaging() throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, entry) in [("../outside", ArchiveHeader.EntryType.regularFile, UInt64(0)),
                               ("/outside", .regularFile, 0),
                               ("Data/link", .link, 0),
                               ("Data/large", .regularFile, BackupArchive.maximumBytes + 1)].enumerated() {
            let file = root.appendingPathComponent("malicious-\(index)")
            try maliciousArchive(file: file, entries: [entry])
            let destination = root.appendingPathComponent("extract-\(index)")
            #expect(throws: (any Error).self) { try BackupArchive.decode(from: file, to: destination, password: "test password") }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
        }
        let file = root.appendingPathComponent("collision")
        try maliciousArchive(file: file, entries: [("Data/File", .regularFile, 0), ("Data/file", .regularFile, 0)])
        #expect(throws: (any Error).self) { try BackupArchive.decode(from: file, to: root.appendingPathComponent("collision-output"), password: "test password") }
    }

    @Test func cancelledExportKeepsPreviousBackup() async throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        let archive = root.appendingPathComponent("existing")
        try Data("previous successful backup".utf8).write(to: archive)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try BackupArchive.encode(directory: source, to: archive, password: "test password")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOf: archive, encoding: .utf8) == "previous successful backup")
    }
    @Test func encryptedRoundTripPreservesNestedBytesAndHidesSecrets() throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Data/DesktopSignIns"), withIntermediateDirectories: true)
        let secret = Data("synthetic-private-token-ONLY-FOR-TESTS".utf8)
        try secret.write(to: source.appendingPathComponent("Data/DesktopSignIns/account.json"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        // Larger than the codec's transfer buffer: catches partial-blob handling.
        let large = Data((0..<2_200_000).map { UInt8($0 % 251) })
        try large.write(to: source.appendingPathComponent("Data/large"))
        let file = root.appendingPathComponent("transfer.codexplusbarbackup")
        try BackupArchive.encode(directory: source, to: file, password: "correct horse 🌳")
        #expect(try Data(contentsOf: file).range(of: secret) == nil)
        let restored = root.appendingPathComponent("restored")
        try BackupArchive.decode(from: file, to: restored, password: "correct horse 🌳")
        #expect(try Data(contentsOf: restored.appendingPathComponent("Data/DesktopSignIns/account.json")) == secret)
        #expect(try Data(contentsOf: restored.appendingPathComponent("Data/large")) == large)
        let permissions = try FileManager.default.attributesOfItem(atPath: restored.appendingPathComponent("Data/large").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func wrongPasswordTamperAndTruncationFailWithoutLeavingExtractedData() throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("synthetic secret".utf8).write(to: source.appendingPathComponent("manifest.json"))
        let file = root.appendingPathComponent("backup")
        try BackupArchive.encode(directory: source, to: file, password: "long password")
        let original = try Data(contentsOf: file)
        for mode in 0..<3 {
            var bytes = original
            if mode == 1 { bytes[bytes.count / 2] ^= 0xff }
            if mode == 2 { bytes.removeLast(20) }
            try bytes.write(to: file)
            let destination = root.appendingPathComponent("bad-\(mode)")
            #expect(throws: (any Error).self) {
                try BackupArchive.decode(from: file, to: destination, password: mode == 0 ? "wrong password" : "long password")
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func refusesSymlinkSourcesAndUnsafePaths() throws {
        let root = try backupTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: root)
        #expect(throws: (any Error).self) {
            try BackupArchive.encode(directory: source, to: root.appendingPathComponent("backup"), password: "long password")
        }
        for path in ["/outside", "../outside", "Data/../outside", "Data//file", "Data/./file", "Data\\file", "", "Data/\u{0}file"] {
            #expect(!BackupArchive.isSafePath(path))
        }
        #expect(BackupArchive.isSafePath("Data/ChromeProfiles/Profile α/Cookies"))
    }
}

private func maliciousArchive(file: URL, entries: [(String, ArchiveHeader.EntryType, UInt64)]) throws {
    try ArchiveByteStream.withFileStream(path: FilePath(file.path), mode: .writeOnly, options: [.create, .truncate], permissions: .init(rawValue: 0o600)) { output in
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
        context.authData = Data("com.linda.CodexPlusBar.backup/1".utf8)
        try context.setPassword(SHA256.hash(data: Data("test password".utf8)).map { String(format: "%02x", $0) }.joined())
        let encrypted = try #require(ArchiveByteStream.encryptionStream(writingTo: output, encryptionContext: context))
        let stream = try #require(ArchiveStream.encodeStream(writingTo: encrypted))
        for (path, type, size) in entries {
            let header = ArchiveHeader()
            header.append(.uint(key: .init("TYP"), value: UInt64(type.rawValue)))
            header.append(.string(key: .init("PAT"), value: path))
            header.append(.blob(key: .init("DAT"), size: size))
            try stream.writeHeader(header)
        }
        // Oversized header intentionally has no blob: the decoder must reject its declared
        // allocation before attempting to read it. Encoder close can report the missing body.
        try? stream.close()
        try encrypted.close()
    }
}

func backupTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}
