import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    private let controller: PlusProfileController
    private let clock: AppMinuteClock
    private let userDefaults: UserDefaults
    private let openManagerWindow: @MainActor (UUID?) -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var defaultsObserver: NSObjectProtocol?

    init(
        controller: PlusProfileController,
        clock: AppMinuteClock,
        userDefaults: UserDefaults = .standard,
        openManagerWindow: @escaping @MainActor (UUID?) -> Void
    ) {
        self.controller = controller
        self.clock = clock
        self.userDefaults = userDefaults
        self.openManagerWindow = openManagerWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
        startObservingPreferences()
        startObservingStatus()
    }

    func start() {
        updateStatusItemAppearance()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("CodexPlusBar")
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: MenuBarPanelMetrics.width, height: MenuBarPanelMetrics.height)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarRootView(
                controller: controller,
                currentTime: clock,
                userDefaults: userDefaults,
                openManagerWindow: { [weak self] profileID in
                    self?.popover.performClose(nil)
                    self?.openManagerWindow(profileID)
                }
            )
        )
    }

    private func startObservingPreferences() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItemAppearance()
            }
        }
    }

    private func startObservingStatus() {
        withObservationTracking {
            _ = controller.statusBarSymbolName
            _ = controller.statusBarText(referenceDate: clock.now)
            _ = controller.dashboardStatus
            _ = controller.isRefreshing
            _ = controller.profiles
            _ = clock.now
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItemAppearance()
                self?.startObservingStatus()
            }
        }

        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else {
            return
        }

        let preferredProfileID = MenuBarProfilePreference.preferredProfileID(
            defaults: userDefaults,
            validProfileIDs: controller.profiles.map(\.id)
        )
        let labelText = controller.statusBarText(
            preferredProfileID: preferredProfileID,
            referenceDate: clock.now
        )
        let title = " \(labelText)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        ]

        button.title = title
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.image = statusImage(named: controller.statusBarSymbolName)
        button.contentTintColor = nil
        button.toolTip = "CodexPlusBar"
        statusItem.length = NSStatusItem.variableLength
    }

    private func statusImage(named systemName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let baseImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        baseImage?.isTemplate = true
        return baseImage
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
