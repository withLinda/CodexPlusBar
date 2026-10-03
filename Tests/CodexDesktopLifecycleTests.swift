import AppKit
import Testing
@testable import CodexPlusBar

@MainActor
struct CodexDesktopLifecycleTests {
    @Test func launchesWithPromptFreeNormalQuitEnabled() {
        let configuration = CodexDesktopApp.openConfiguration()
        #expect(configuration.environment["CODEX_ELECTRON_DISABLE_QUIT_CONFIRMATION"] == "1")
        #expect(configuration.activates)
    }

    @Test func normalShutdownNeverUsesForce() async throws {
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        clock.onSleep = { app.isTerminated = true }
        try await close([app], clock: clock)
        #expect(app.requests == ["quit"])
    }

    @Test func blockedQuitFallsBackToForceAndWaitsForActualExit() async throws {
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        clock.onSleep = {
            if app.requests.contains("force") { app.isTerminated = true }
        }
        try await close([app], clock: clock)
        #expect(app.requests == ["quit", "force"])
        #expect(app.isTerminated)
        #expect(clock.elapsed >= .seconds(13))
    }

    @Test func backendGetsItsOwnDrainBudgetAfterDelayedNormalExit() async throws {
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        clock.onSleep = { if clock.elapsed >= .seconds(11) { app.isTerminated = true } }
        try await close([app], clock: clock, hasBundledProcesses: { clock.elapsed < .seconds(18) })
        #expect(app.requests == ["quit"])
        #expect(clock.elapsed == .seconds(18))
    }

    @Test func forceOnlyTargetsSurvivorsOfTheOriginalQuitRequest() async throws {
        let exited = DesktopTerminationStub()
        let blocked = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        clock.onSleep = {
            exited.isTerminated = true
            if blocked.requests.contains("force") { blocked.isTerminated = true }
        }
        try await close([exited, blocked], clock: clock)
        #expect(exited.requests == ["quit"])
        #expect(blocked.requests == ["quit", "force"])
    }

    @Test func rejectedGracefulRequestStillUsesBoundedForceFallback() async throws {
        let app = DesktopTerminationStub(acceptsQuit: false)
        let clock = DesktopShutdownClock()
        clock.onSleep = {
            if app.requests.contains("force") { app.isTerminated = true }
        }
        try await close([app], clock: clock)
        #expect(app.requests == ["quit", "force"])
        #expect(app.isTerminated)
    }

    @Test func successfulForceRequestIsNotProofOfExit() async {
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        await #expect(throws: CodexDesktopCloseError.self) { try await close([app], clock: clock) }
        #expect(app.requests == ["quit", "force"])
        #expect(clock.elapsed == .seconds(24))
    }

    @Test func survivingBackendPreventsSuccessfulClose() async {
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        clock.onSleep = {
            if app.requests.contains("force") { app.isTerminated = true }
        }
        await #expect(throws: CodexDesktopCloseError.self) {
            try await close([app], clock: clock, hasBundledProcesses: { true })
        }
        #expect(app.requests == ["quit", "force"])
    }

    @Test func alreadyClosedAppNeedsNoTerminationRequest() async throws {
        let app = DesktopTerminationStub()
        app.isTerminated = true
        let clock = DesktopShutdownClock()
        try await close([app], clock: clock)
        #expect(app.requests.isEmpty)
        #expect(clock.elapsed == .zero)
    }

    @Test func cancellationBeforeCloseSendsNoQuitRequest() async {
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await close([app], clock: clock)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(app.requests.isEmpty)
    }

    @Test func cancellationDuringGracefulWaitNeverEscalatesToForce() async {
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        clock.onSleep = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { @MainActor in try await close([app], clock: clock) }
        await #expect(throws: CodexDesktopCloseError.self) { try await task.value }
        #expect(app.requests == ["quit"])
        #expect(clock.elapsed == .seconds(12))
    }

    @Test(arguments: ["success", "stuckBackend", "forceRejected"])
    func credentialsStayUntouchedUntilForcedAppAndBackendExit(scenario: String) async throws {
        let fixture = try NativeSwitchFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget()
        let original = try Data(contentsOf: fixture.authURL)
        let app = DesktopTerminationStub(acceptsForce: scenario != "forceRejected")
        let clock = DesktopShutdownClock()
        clock.onSleep = {
            #expect((try? Data(contentsOf: fixture.authURL)) == original)
            if app.acceptsForce, app.requests.contains("force") { app.isTerminated = true }
        }
        let adapter = DesktopLifecycleAdapter(app: app, clock: clock, hasBundledProcesses: {
            scenario == "stuckBackend" || clock.elapsed < .seconds(18)
        })
        let codexHome = fixture.home.appendingPathComponent(".codex")
        let service = CodexAccountSwitchService(
            homeDirectory: fixture.home, app: adapter, verifier: NativeVerifierStub(),
            resolveStore: { try CodexLiveAuthStore(codexHome: codexHome, keychain: MemoryCodexKeychain()) }
        )
        if scenario != "success" {
            do {
                try await service.switchAndOpen(profile: profile)
                Issue.record("A surviving desktop or backend must prevent the credential write")
            } catch let error as CodexSignInSwitchError {
                #expect(error.recovery == .unchanged)
            }
            #expect(try Data(contentsOf: fixture.authURL) == original)
        } else {
            try await service.switchAndOpen(profile: profile)
            #expect(try CodexSignIn(data: Data(contentsOf: fixture.authURL)).identity == profile.codexSignIn)
        }
        #expect(app.requests == ["quit", "force"])
        #expect(adapter.openCount == 1)
    }

    @Test(arguments: [false, true])
    func cancellationDuringBackendDrainPreservesCredentialsAndReopens(forced: Bool) async throws {
        let fixture = try NativeSwitchFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.installTarget()
        let original = try Data(contentsOf: fixture.authURL)
        let app = DesktopTerminationStub()
        let clock = DesktopShutdownClock()
        let exitAt: Duration = forced ? .seconds(13) : .seconds(1)
        clock.onSleep = {
            if clock.elapsed >= exitAt { app.isTerminated = true }
            if clock.elapsed > exitAt { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let adapter = DesktopLifecycleAdapter(app: app, clock: clock, hasBundledProcesses: {
            clock.elapsed < exitAt + .seconds(4)
        })
        let codexHome = fixture.home.appendingPathComponent(".codex")
        let service = CodexAccountSwitchService(
            homeDirectory: fixture.home, app: adapter, verifier: NativeVerifierStub(),
            resolveStore: { try CodexLiveAuthStore(codexHome: codexHome, keychain: MemoryCodexKeychain()) }
        )
        let task = Task { try await service.switchAndOpen(profile: profile) }
        do {
            try await task.value
            Issue.record("A cancelled switch must not install the selected sign-in")
        } catch let error as CodexSignInSwitchError {
            #expect(error.recovery == .unchanged)
            #expect(error.reopenFailed == false)
        }
        #expect(task.isCancelled)
        #expect(try Data(contentsOf: fixture.authURL) == original)
        #expect(app.requests == (forced ? ["quit", "force"] : ["quit"]))
        #expect(clock.elapsed == exitAt + .seconds(4))
        #expect(adapter.openCount == 1)
    }

    private func close(_ apps: [DesktopTerminationStub], clock: DesktopShutdownClock,
                       hasBundledProcesses: @escaping @MainActor () -> Bool = { false }) async throws {
        try await CodexDesktopApp.close(apps: apps, hasBundledProcesses: hasBundledProcesses,
                                        now: { clock.now }, pause: { await clock.sleep() })
    }
}

@MainActor
private final class DesktopLifecycleAdapter: CodexDesktopAppManaging {
    let app: DesktopTerminationStub
    let clock: DesktopShutdownClock
    let hasBundledProcesses: @MainActor () -> Bool
    var openCount = 0

    init(app: DesktopTerminationStub, clock: DesktopShutdownClock,
         hasBundledProcesses: @escaping @MainActor () -> Bool) {
        self.app = app
        self.clock = clock
        self.hasBundledProcesses = hasBundledProcesses
    }

    func close() async throws {
        try await CodexDesktopApp.close(apps: [app], hasBundledProcesses: hasBundledProcesses,
                                        now: { clock.now }, pause: { await clock.sleep() })
    }

    func open() { openCount += 1 }
}

@MainActor
private final class DesktopTerminationStub: CodexDesktopRunningApplication {
    var isTerminated = false
    var requests: [String] = []
    let acceptsQuit: Bool
    let acceptsForce: Bool

    init(acceptsQuit: Bool = true, acceptsForce: Bool = true) {
        self.acceptsQuit = acceptsQuit
        self.acceptsForce = acceptsForce
    }
    func terminate() -> Bool { requests.append("quit"); return acceptsQuit }
    func forceTerminate() -> Bool { requests.append("force"); return acceptsForce }
}

@MainActor
private final class DesktopShutdownClock {
    private let start = ContinuousClock.now
    var elapsed: Duration = .zero
    var now: ContinuousClock.Instant { start.advanced(by: elapsed) }
    var onSleep: () -> Void = {}

    func sleep() async {
        elapsed += .seconds(1)
        onSleep()
        await Task.yield()
    }
}
