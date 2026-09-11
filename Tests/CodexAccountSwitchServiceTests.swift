import Foundation
import Testing
@testable import CodexPlusBar

struct CodexAccountSwitchServiceTests {
    @Test(arguments: [Int32(0), Int32(1)])
    func confirmedSwitchAlwaysReopens(exitCode: Int32) async throws {
        var events: [String] = []
        try await CodexSwitchWorkflow.perform(
            close: { events.append("close") },
            switchAccount: { events.append("switch"); return exitCode },
            verifyAccount: { events.append("verify"); return true },
            reopen: { events.append("open"); return 0 }
        )
        #expect(events == ["close", "switch", "verify", "open"])
    }

    @Test
    func failedSwitchReopensBeforeReportingFailure() async throws {
        var reopened = false
        await #expect(throws: CodexSwitchError.commandFailed("codex-auth returned exit code 7")) {
            try await CodexSwitchWorkflow.perform(
                close: {}, switchAccount: { 7 }, verifyAccount: { false },
                reopen: { reopened = true; return 0 }
            )
        }
        #expect(reopened)
    }

    @Test
    func switchSpawnFailureStillReopens() async throws {
        var reopened = false
        await #expect(throws: CodexSwitchError.codexAuthMissing) {
            try await CodexSwitchWorkflow.perform(
                close: {}, switchAccount: { throw CodexSwitchError.codexAuthMissing },
                verifyAccount: { false }, reopen: { reopened = true; return 0 }
            )
        }
        #expect(reopened)
    }

    @Test(arguments: [true, false])
    func reopenFailureCannotBeHiddenByRegistry(switched: Bool) async throws {
        await #expect(throws: CodexSwitchError.reopenFailed(switched: switched)) {
            try await CodexSwitchWorkflow.perform(
                close: {}, switchAccount: { 0 }, verifyAccount: { switched }, reopen: { 1 }
            )
        }
    }

    @Test
    func reopenSpawnFailureIsReportedAsLaunchFailure() async throws {
        await #expect(throws: CodexSwitchError.reopenFailed(switched: true)) {
            try await CodexSwitchWorkflow.perform(
                close: {}, switchAccount: { 0 }, verifyAccount: { true },
                reopen: { throw CocoaError(.fileNoSuchFile) }
            )
        }
    }

    @Test
    func closeFailureDoesNotSwitchOrOpen() async throws {
        var reachedSwitch = false
        var reachedOpen = false
        await #expect(throws: CodexSwitchError.chatGPTCouldNotClose) {
            try await CodexSwitchWorkflow.perform(
                close: { throw CodexSwitchError.chatGPTCouldNotClose },
                switchAccount: { reachedSwitch = true; return 0 }, verifyAccount: { true },
                reopen: { reachedOpen = true; return 0 }
            )
        }
        #expect(!reachedSwitch && !reachedOpen)
    }

    @Test
    func zeroExitWithoutSelectedAccountIsNotSuccess() async throws {
        var reopened = false
        await #expect(throws: CodexSwitchError.commandFailed("the selected login was not activated")) {
            try await CodexSwitchWorkflow.perform(
                close: {}, switchAccount: { 0 }, verifyAccount: { false },
                reopen: { reopened = true; return 0 }
            )
        }
        #expect(reopened)
    }

    // Execute the production process runner and close script, not just compare
    // script text. All paths are unique test fixtures; no real app is closed.
    @Test(arguments: [Int32(0), Int32(7)])
    func realProcessesReachReopenAfterSwitch(switchExit: Int32) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("switch-test-\(UUID()) ' spaced")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events")
        let selected = "account'with spaces@example.com"
        var verified = false
        try await CodexSwitchWorkflow.perform(
            close: {
                let result = try await CodexSwitchProcess.run(
                    executable: "/bin/zsh", arguments: ["-f", "-c",
                        CodexAccountSwitchService.closeScript(appPath: directory.appendingPathComponent("Fake.app").path)]
                )
                #expect(result == 0)
            },
            switchAccount: {
                try await CodexSwitchProcess.run(executable: "/bin/sh", arguments: [
                    "-c", "printf 'switch:%s\\n' \"$2\" >> \"$1\"; exit \"$3\"", "fixture",
                    log.path, selected, String(switchExit)
                ])
            },
            verifyAccount: { verified = true; return true },
            reopen: {
                #expect(verified)
                return try await CodexSwitchProcess.run(executable: "/bin/sh", arguments: [
                    "-c", "printf 'open\\n' >> \"$1\"", "fixture", log.path
                ])
            }
        )
        #expect(try String(contentsOf: log, encoding: .utf8) == "switch:\(selected)\nopen\n")
    }

    @Test
    func fastExitingChildrenCompleteReliably() async throws {
        for _ in 0..<20 {
            let result = try await CodexSwitchProcess.run(executable: "/usr/bin/true", arguments: [])
            #expect(result == 0)
        }
    }
}
