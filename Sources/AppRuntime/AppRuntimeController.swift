import AppKit
import Foundation

@MainActor
final class AppRuntimeController {
    let controller: PlusProfileController
    let clock: AppMinuteClock

    private let profileManagerWindowPresenter: ProfileManagerWindowPresenter
    private let singleInstanceCoordinator: SingleInstanceCoordinator
    private lazy var menuBarStatusItemController = MenuBarStatusItemController(
        controller: controller,
        clock: clock,
        openManagerWindow: { [weak self] profileID in
            self?.showManagerWindow(selecting: profileID)
        }
    )
    private var hasStarted = false
    private var localReopenObserver: Any?

    init(singleInstanceCoordinator: SingleInstanceCoordinator = SingleInstanceCoordinator()) {
        let controller = PlusProfileController()
        let clock = AppMinuteClock()
        self.controller = controller
        self.clock = clock
        self.profileManagerWindowPresenter = ProfileManagerWindowPresenter(
            controller: controller,
            clock: clock
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

        menuBarStatusItemController.start()
        clock.start()
    }

    func showManagerWindow(selecting profileID: UUID? = nil) {
        profileManagerWindowPresenter.show(selecting: profileID)
    }
}
