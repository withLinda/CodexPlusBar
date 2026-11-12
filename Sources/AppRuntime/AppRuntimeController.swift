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
    let cloudSync: CloudSyncCoordinator
    let cloudPresentation: CloudSyncPresentation

    private let chromeProfileStore: ChromeProfileStore
    private let profileManagerWindowPresenter: ProfileManagerWindowPresenter
    private let emailToolsWindowPresenter: EmailToolsWindowPresenter
    private let emailController: DotTrickController
    private let backupPresenter: BackupTransferPresenter
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
    private var terminationObserver: Any?
    private var cloudObservers: [NSObjectProtocol] = []
    private var startupTask: Task<Void, Never>?

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
            selectorPublisher: SelectorExportPublisher(),
            autoStart: false
        )
        let dotTrickController = DotTrickController()
        let clock = AppMinuteClock()
        self.controller = controller
        self.clock = clock
        self.emailController = dotTrickController
        let cloudSync = CloudSyncCoordinator(profiles: controller)
        self.cloudSync = cloudSync
        self.cloudPresentation = CloudSyncPresentation(coordinator: cloudSync)
        let transfer = BackupTransferController(profiles: controller, email: dotTrickController, cloudSync: cloudSync)
        self.backupPresenter = BackupTransferPresenter(controller: transfer)
        self.chromeProfileStore = chromeProfileStore
        self.profileManagerWindowPresenter = ProfileManagerWindowPresenter(
            controller: controller,
            clock: clock
        )
        self.emailToolsWindowPresenter = EmailToolsWindowPresenter(
            controller: dotTrickController
        )
        self.singleInstanceCoordinator = singleInstanceCoordinator
        self.profileManagerWindowPresenter.openBackup = { [weak self] mode in self?.showBackup(mode) }
        self.profileManagerWindowPresenter.cloudSync = cloudPresentation
        transfer.showProfiles = { [weak self] in self?.showManagerWindow() }
    }

    func start() {
        guard hasStarted == false else { return }
        hasStarted = true
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.startupTask?.cancel()
                    self?.controller.stopBackgroundTasks()
                    self?.clock.stop()
                    Task { @MainActor in await self?.cloudSync.stop() }
                }
            }

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

        CodexCloudLifecycle.shutdown = { [weak self] in
            self?.startupTask?.cancel()
            self?.controller.stopBackgroundTasks()
            self?.clock.stop()
            await self?.cloudSync.stop()
        }

        startupTask = Task { @MainActor in await finishStartup() }
    }

    private func finishStartup() async {
        let root = ProfileCatalogStore.defaultFileURL().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(BackupService.receiptName).path) {
            do {
                emailController.isTransferring = true
                try await controller.pauseForBackup()
                try await BackupSessionBridge.finishRestore(root: root)
                emailController.loadFromDisk()
                emailController.isTransferring = false
                controller.resumeAfterBackup(reload: true, startTasks: false)
            } catch {
                controller.statusMessage = "Restore needs to finish before profiles can be used. Reopen CodexPlusBar to retry."
                menuBarStatusItemController.start()
                showManagerWindow()
                return
            }
        }
        do {
            let report = try chromeProfileStore.migrateAndPrune(
                profiles: controller.storedProfiles
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

        await Self.startServices(controller: controller, clock: clock, cloudSync: cloudSync,
            showStatusItem: { self.menuBarStatusItemController.start() },
            configureCloudNotifications: { self.configureCloudNotifications() })
    }

    static func startServices(controller: PlusProfileController, clock: AppMinuteClock,
                              cloudSync: CloudSyncCoordinator,
                              showStatusItem: @MainActor () -> Void,
                              configureCloudNotifications: @MainActor () -> Void) async {
        guard !Task.isCancelled else { return }
        showStatusItem()
        clock.start()
        configureCloudNotifications()
        await cloudSync.start(localServicesReady: { controller.startBackgroundTasks() })
    }

    private func configureCloudNotifications() {
        for name in [NSApplication.didBecomeActiveNotification, CodexCloudNotifications.received, CodexCloudNotifications.accountChanged] {
            cloudObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.cloudSync.syncNow() }
            })
        }
        cloudObservers.append(NotificationCenter.default.addObserver(forName: CodexCloudNotifications.registrationFailed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudSync.notificationRegistrationFailed() }
        })
        cloudObservers.append(NotificationCenter.default.addObserver(forName: CodexCloudNotifications.registered, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudSync.notificationRegistrationSucceeded() }
        })
        if CloudSyncAvailability().environment != nil {
            NSApplication.shared.registerForRemoteNotifications(matching: [])
        }
    }

    func showManagerWindow(selecting profileID: UUID? = nil) {
        profileManagerWindowPresenter.show(selecting: profileID)
    }

    func showEmailToolsWindow() {
        emailToolsWindowPresenter.show()
    }

    func showBackup(_ mode: BackupTransferMode) {
        backupPresenter.show(mode)
    }
}
