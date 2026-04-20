import Testing
@testable import CodexPlusBar

@MainActor
struct SingleInstanceCoordinatorTests {
    @Test
    func primaryInstanceKeepsRunningAndRegistersObserver() {
        let runningInstanceChecker = StubRunningInstanceChecker(hasOtherInstance: false)
        let signalBus = SpyReopenSignalBus()
        let coordinator = SingleInstanceCoordinator(
            bundleIdentifierProvider: { "com.linda.CodexPlusBar" },
            processIdentifierProvider: { 42 },
            runningInstanceChecker: runningInstanceChecker,
            signalBus: signalBus
        )

        let action = coordinator.activate { }

        #expect(action == .continueRunning)
        #expect(runningInstanceChecker.lastBundleIdentifier == "com.linda.CodexPlusBar")
        #expect(runningInstanceChecker.lastProcessIdentifier == 42)
        #expect(signalBus.observedBundleIdentifiers == ["com.linda.CodexPlusBar"])
        #expect(signalBus.postedBundleIdentifiers.isEmpty)
    }

    @Test
    func secondaryInstanceSignalsExistingAppAndTerminates() {
        let runningInstanceChecker = StubRunningInstanceChecker(hasOtherInstance: true)
        let signalBus = SpyReopenSignalBus()
        let coordinator = SingleInstanceCoordinator(
            bundleIdentifierProvider: { "com.linda.CodexPlusBar" },
            processIdentifierProvider: { 77 },
            runningInstanceChecker: runningInstanceChecker,
            signalBus: signalBus
        )

        let action = coordinator.activate { }

        #expect(action == .terminate)
        #expect(signalBus.postedBundleIdentifiers == ["com.linda.CodexPlusBar"])
        #expect(signalBus.observedBundleIdentifiers.isEmpty)
    }

    @Test
    func reopenSignalTriggersHandlerForPrimaryInstance() {
        let signalBus = SpyReopenSignalBus()
        let coordinator = SingleInstanceCoordinator(
            bundleIdentifierProvider: { "com.linda.CodexPlusBar" },
            processIdentifierProvider: { 11 },
            runningInstanceChecker: StubRunningInstanceChecker(hasOtherInstance: false),
            signalBus: signalBus
        )
        var reopenCount = 0

        let action = coordinator.activate {
            reopenCount += 1
        }
        signalBus.simulateReopen(for: "com.linda.CodexPlusBar")

        #expect(action == .continueRunning)
        #expect(reopenCount == 1)
    }
}

@MainActor
private final class StubRunningInstanceChecker: RunningInstanceChecking {
    let hasOtherInstance: Bool
    private(set) var lastBundleIdentifier: String?
    private(set) var lastProcessIdentifier: Int32?

    init(hasOtherInstance: Bool) {
        self.hasOtherInstance = hasOtherInstance
    }

    func hasOtherRunningInstance(bundleIdentifier: String, currentProcessIdentifier: Int32) -> Bool {
        lastBundleIdentifier = bundleIdentifier
        lastProcessIdentifier = currentProcessIdentifier
        return hasOtherInstance
    }
}

@MainActor
private final class SpyReopenSignalBus: ReopenSignalBus {
    private(set) var observedBundleIdentifiers: [String] = []
    private(set) var postedBundleIdentifiers: [String] = []
    private var handlers: [String: @MainActor () -> Void] = [:]

    func observeReopenRequests(
        for bundleIdentifier: String,
        using handler: @escaping @MainActor () -> Void
    ) -> Any {
        observedBundleIdentifiers.append(bundleIdentifier)
        handlers[bundleIdentifier] = handler
        return bundleIdentifier
    }

    func postReopenRequest(for bundleIdentifier: String) {
        postedBundleIdentifiers.append(bundleIdentifier)
    }

    func simulateReopen(for bundleIdentifier: String) {
        handlers[bundleIdentifier]?()
    }
}
