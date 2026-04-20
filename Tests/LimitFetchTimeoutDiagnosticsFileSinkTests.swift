import Foundation
import Testing
@testable import CodexPlusBar

struct LimitFetchTimeoutDiagnosticsFileSinkTests {
    @Test
    func recordTimeoutWritesLineDelimitedEntry() async throws {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let logFileURL = directoryURL.appendingPathComponent("limit-timeouts.log", isDirectory: false)
        let sink = LimitFetchTimeoutDiagnosticsFileSink(logFileURL: logFileURL)
        let diagnostics = makeTimeoutDiagnostics(
            accountID: "workspace-a",
            checkpoint: .request
        )

        await sink.recordTimeout(diagnostics)

        let contents = try String(contentsOf: logFileURL, encoding: .utf8)
        #expect(contents == "\(diagnostics.logLine())\n")
    }

    @Test
    func recordTimeoutAppendsWithoutOverwritingExistingEntries() async throws {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let logFileURL = directoryURL.appendingPathComponent("limit-timeouts.log", isDirectory: false)
        let sink = LimitFetchTimeoutDiagnosticsFileSink(logFileURL: logFileURL)
        let first = makeTimeoutDiagnostics(accountID: "workspace-a", checkpoint: .switchAccount)
        let second = makeTimeoutDiagnostics(accountID: "workspace-b", checkpoint: .restore)

        await sink.recordTimeout(first)
        await sink.recordTimeout(second)

        let contents = try String(contentsOf: logFileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        #expect(lines == [first.logLine(), second.logLine()])
    }
}

private func makeTimeoutDiagnostics(
    accountID: String,
    checkpoint: LimitFetchTimeoutCheckpoint
) -> LimitFetchTimeoutDiagnostics {
    LimitFetchTimeoutDiagnostics(
        accountID: accountID,
        sweepIndex: 1,
        sweepTotal: 3,
        checkpoint: checkpoint,
        elapsedMilliseconds: 20_345,
        timeoutMilliseconds: 20_000,
        thresholdMilliseconds: 10_000,
        sessionAccountBefore: "workspace-before",
        sessionAccountAfter: "workspace-after",
        accountCookieBefore: "cookie-before",
        accountCookieAfter: "cookie-after"
    )
}

