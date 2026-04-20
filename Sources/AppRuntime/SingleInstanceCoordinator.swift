import AppKit
import Foundation

enum CodexAppNotifications {
    static let reopenAccountWindowLocally = Notification.Name("CodexPlusBar.reopenAccountWindowLocally")

    static func reopenAccountWindowDistributed(bundleIdentifier: String) -> Notification.Name {
        Notification.Name("\(bundleIdentifier).reopenAccountWindow")
    }
}

enum SingleInstanceLaunchAction: Equatable {
    case continueRunning
    case terminate
}

@MainActor
protocol RunningInstanceChecking {
    func hasOtherRunningInstance(bundleIdentifier: String, currentProcessIdentifier: Int32) -> Bool
}

@MainActor
protocol ReopenSignalBus {
    func observeReopenRequests(
        for bundleIdentifier: String,
        using handler: @escaping @MainActor () -> Void
    ) -> Any

    func postReopenRequest(for bundleIdentifier: String)
}

struct RunningApplicationChecker: RunningInstanceChecking {
    func hasOtherRunningInstance(bundleIdentifier: String, currentProcessIdentifier: Int32) -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentProcessIdentifier }
    }
}

final class DistributedReopenSignalBus: ReopenSignalBus {
    private let center: DistributedNotificationCenter

    init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    func observeReopenRequests(
        for bundleIdentifier: String,
        using handler: @escaping @MainActor () -> Void
    ) -> Any {
        center.addObserver(
            forName: CodexAppNotifications.reopenAccountWindowDistributed(bundleIdentifier: bundleIdentifier),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    func postReopenRequest(for bundleIdentifier: String) {
        center.postNotificationName(
            CodexAppNotifications.reopenAccountWindowDistributed(bundleIdentifier: bundleIdentifier),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

@MainActor
final class SingleInstanceCoordinator {
    private let bundleIdentifierProvider: () -> String?
    private let processIdentifierProvider: () -> Int32
    private let runningInstanceChecker: any RunningInstanceChecking
    private let signalBus: any ReopenSignalBus
    private var distributedObserver: Any?

    init(
        bundleIdentifierProvider: @escaping () -> String? = { Bundle.main.bundleIdentifier },
        processIdentifierProvider: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        runningInstanceChecker: any RunningInstanceChecking = RunningApplicationChecker(),
        signalBus: any ReopenSignalBus = DistributedReopenSignalBus()
    ) {
        self.bundleIdentifierProvider = bundleIdentifierProvider
        self.processIdentifierProvider = processIdentifierProvider
        self.runningInstanceChecker = runningInstanceChecker
        self.signalBus = signalBus
    }

    func activate(onReopenRequest: @escaping @MainActor () -> Void) -> SingleInstanceLaunchAction {
        guard let bundleIdentifier = bundleIdentifierProvider(), bundleIdentifier.isEmpty == false else {
            return .continueRunning
        }

        let currentProcessIdentifier = processIdentifierProvider()
        if runningInstanceChecker.hasOtherRunningInstance(
            bundleIdentifier: bundleIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        ) {
            signalBus.postReopenRequest(for: bundleIdentifier)
            return .terminate
        }

        distributedObserver = signalBus.observeReopenRequests(
            for: bundleIdentifier,
            using: onReopenRequest
        )
        return .continueRunning
    }
}
