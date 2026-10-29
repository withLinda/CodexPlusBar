import Foundation

enum BackupBrowserGuard {
    /// Read process arguments only to detect a remaining writer to the app's dedicated tree.
    /// Never terminate the user's regular Chrome or read its profile databases.
    static func check(root: URL) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "args="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BackupError.busy }
        let paths = [root.path, root.resolvingSymlinksInPath().path]
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        guard !lines.contains(where: { line in
            line.contains("--user-data-dir") && paths.contains(where: { line.contains($0 + "/ChromeProfiles") })
        }) else { throw BackupError.changed }
    }
}
