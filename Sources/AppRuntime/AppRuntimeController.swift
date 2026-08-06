import AppKit
import Foundation
import OSLog

@MainActor
final class AppRuntimeController {
    private static let logger = Logger(
        subsystem: "com.linda.CodexPlusBar",
        category: "ChromeStorage"
    )

    let controller: PlusProfileController
    let clock: AppMinuteClock

    private let chromeProfileStore: ChromeProfileStore
    private let profileManagerWindowPresenter: ProfileManagerWindowPresenter
    private let emailToolsWindowPresenter: EmailToolsWindowPresenter
    private let singleInstanceCoordinator: SingleInstanceCoordinator
    private lazy var menuBarStatusItemController = MenuBarStatusItemController(
        controller: controller,
        clock: clock,
        openManagerWindow: { [weak self] profileID in
            self?.showManagerWindow(selecting: profileID)
        },
        openEmailToolsWindow: { [weak self] in
            self?.showEmailToolsWindow()
        }
    )
    private var hasStarted = false
    private var localReopenObserver: Any?

    init(singleInstanceCoordinator: SingleInstanceCoordinator = SingleInstanceCoordinator()) {
        let chromeProfileStore = ChromeProfileStore()
        let chromeLauncher = ChromeLauncher(profileStore: chromeProfileStore)
        let chromeSessionManager = DefaultChromeSessionManager(
            launcher: chromeLauncher,
            profileStore: chromeProfileStore
        )
        let dataService = PlusProfileDataService(
            chromeSessionManager: chromeSessionManager
        )
        let controller = PlusProfileController(
            dataService: dataService,
            autoStart: false
        )
        let dotTrickController = DotTrickController()
        let clock = AppMinuteClock()
        self.controller = controller
        self.clock = clock
        self.chromeProfileStore = chromeProfileStore
        self.profileManagerWindowPresenter = ProfileManagerWindowPresenter(
            controller: controller,
            clock: clock
        )
        self.emailToolsWindowPresenter = EmailToolsWindowPresenter(
            controller: dotTrickController
        )
        self.singleInstanceCoordinator = singleInstanceCoordinator
    }

    func start() {
        guard hasStarted == false else { return }
        hasStarted = true

        localReopenObserver = NotificationCenter.default.addObserver(
            forName: CodexAppNotifications.reopenAccountWindowLocally,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showManagerWindow()
            }
        }

        let launchAction = singleInstanceCoordinator.activate { [weak self] in
            self?.showManagerWindow()
        }

        if launchAction == .terminate {
            NSApplication.shared.terminate(nil)
            return
        }

        do {
            let report = try chromeProfileStore.migrateAndPrune(
                profiles: controller.profiles.map(\.profile)
            )
            Self.logger.info(
                "Chrome storage prepared: migrated=\(report.migratedProfileCount, privacy: .public), orphans=\(report.removedOrphanCount, privacy: .public), disposableItems=\(report.removedDisposableItemCount, privacy: .public)"
            )
        } catch {
            // A failed cleanup must not prevent the app from opening.  The
            // launcher still performs per-profile migration on demand.
            controller.statusMessage = "Chrome storage cleanup will retry next time."
            Self.logger.error("Chrome storage preparation failed: \(String(describing: error), privacy: .public)")
        }

        controller.startBackgroundTasks()
        menuBarStatusItemController.start()
        clock.start()
    }

    func showManagerWindow(selecting profileID: UUID? = nil) {
        profileManagerWindowPresenter.show(selecting: profileID)
    }

    func showEmailToolsWindow() {
        emailToolsWindowPresenter.show()
    }
}
