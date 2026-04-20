import Foundation

protocol LimitFetchTimeoutDiagnosticsSinking: Sendable {
    func recordTimeout(_ diagnostics: LimitFetchTimeoutDiagnostics) async
}

actor LimitFetchTimeoutDiagnosticsFileSink: LimitFetchTimeoutDiagnosticsSinking {
    private let logFileURL: URL
    private let fileManager: FileManager

    init(
        logFileURL: URL = LimitFetchTimeoutDiagnosticsFileSink.defaultLogFileURL(),
        fileManager: FileManager = .default
    ) {
        self.logFileURL = logFileURL
        self.fileManager = fileManager
    }

    func recordTimeout(_ diagnostics: LimitFetchTimeoutDiagnostics) async {
        append(line: diagnostics.logLine())
    }

    private func append(line: String) {
        let lineToWrite = line.hasSuffix("\n") ? line : "\(line)\n"
        let data = Data(lineToWrite.utf8)

        do {
            let directoryURL = logFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL, options: .atomic)
            }
        } catch {
#if DEBUG
            fputs("[CodexPlusBar] failed to persist timeout diagnostics: \(error)\n", stderr)
#endif
        }
    }

    nonisolated static let live = LimitFetchTimeoutDiagnosticsFileSink()

    nonisolated static func defaultLogFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let overridePath = environment["CODEXPLUSBAR_TIMEOUT_DIAGNOSTICS_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           overridePath.isEmpty == false {
            return URL(fileURLWithPath: overridePath)
        }

        if let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return applicationSupportURL
                .appendingPathComponent("CodexPlusBar", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("limit-fetch-timeouts.log", isDirectory: false)
        }

        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codexteambar", isDirectory: true)
            .appendingPathComponent("limit-fetch-timeouts.log", isDirectory: false)
    }
}
