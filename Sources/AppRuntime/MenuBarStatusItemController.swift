import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    private let controller: PlusProfileController
    private let clock: AppMinuteClock
    private let userDefaults: UserDefaults
    private let openManagerWindow: @MainActor (UUID?) -> Void
    private let openEmailToolsWindow: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var defaultsObserver: NSObjectProtocol?

    init(
        controller: PlusProfileController,
        clock: AppMinuteClock,
        userDefaults: UserDefaults = .standard,
        openManagerWindow: @escaping @MainActor (UUID?) -> Void,
        openEmailToolsWindow: @escaping @MainActor () -> Void
    ) {
        self.controller = controller
        self.clock = clock
        self.userDefaults = userDefaults
        self.openManagerWindow = openManagerWindow
        self.openEmailToolsWindow = openEmailToolsWindow
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
                },
                openEmailToolsWindow: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openEmailToolsWindow()
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
            _ = controller.statusBarContent(referenceDate: clock.now).plainText
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
        let content = controller.statusBarContent(
            preferredProfileID: preferredProfileID,
            referenceDate: clock.now
        )

        button.attributedTitle = statusTitle(for: content)
        button.image = statusImage(named: controller.statusBarSymbolName)
        button.contentTintColor = nil
        button.toolTip = "CodexPlusBar"
        button.setAccessibilityLabel("CodexPlusBar \(content.accessibilityText)")
        statusItem.length = NSStatusItem.variableLength
    }

    private func statusTitle(for content: MenuBarStatusContent) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        ]

        title.append(NSAttributedString(string: " ", attributes: attributes))

        guard content.showsUsageSummary else {
            title.append(NSAttributedString(string: content.plainText, attributes: attributes))
            return title
        }

        title.append(NSAttributedString(string: content.profileLabel, attributes: attributes))
        title.append(NSAttributedString(string: " ", attributes: attributes))
        title.append(statusSymbolAttachment(named: "hourglass.circle"))
        title.append(NSAttributedString(string: " \(content.fiveHourText) ", attributes: attributes))
        title.append(statusSymbolAttachment(named: "7.calendar"))
        title.append(NSAttributedString(string: " \(content.sevenDayText)", attributes: attributes))

        return title
    }

    private func statusSymbolAttachment(named systemName: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -1.6, width: 11.5, height: 11.5)
        return NSAttributedString(attachment: attachment)
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
