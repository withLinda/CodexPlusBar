import Darwin
import Foundation

struct SelectorExportStore: Sendable {
    let file: URL
    private let beforeRename: @Sendable () throws -> Void

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         beforeRename: @escaping @Sendable () throws -> Void = {}) {
        file = homeDirectory.appendingPathComponent("Library/Application Support/CodexPlusBar/Exports/openchamber-selector-v1.json")
        self.beforeRename = beforeRename
    }

    func write(_ snapshot: SelectorExport) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576, snapshot.accounts.count <= 256 else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".selector-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        try beforeRename()
        guard rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
    }
}
