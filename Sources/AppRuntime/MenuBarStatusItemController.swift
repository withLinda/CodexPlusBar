import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    private let controller: PlusProfileController
    private let clock: AppMinuteClock
    private let openManagerWindow: @MainActor (UUID?) -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(
        controller: PlusProfileController,
        clock: AppMinuteClock,
        openManagerWindow: @escaping @MainActor (UUID?) -> Void
    ) {
        self.controller = controller
        self.clock = clock
        self.openManagerWindow = openManagerWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
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
                openManagerWindow: { [weak self] profileID in
                    self?.popover.performClose(nil)
                    self?.openManagerWindow(profileID)
                }
            )
        )
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

        let labelText = controller.statusBarText(referenceDate: clock.now)
        let color = statusItemColor
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        ]

        button.attributedTitle = NSAttributedString(string: " \(labelText)", attributes: attributes)
        button.image = statusImage(named: controller.statusBarSymbolName, color: color)
        button.contentTintColor = color
        button.toolTip = "CodexPlusBar"
        statusItem.length = NSStatusItem.variableLength
    }

    private var statusItemColor: NSColor {
        if controller.dashboardStatus == .ready,
           let urgent = controller.readyProfiles.min(by: {
               ($0.usage?.fiveHourRemainingPercent ?? 101) < ($1.usage?.fiveHourRemainingPercent ?? 101)
           }),
           let remaining = urgent.usage?.fiveHourRemainingPercent {
            return remaining <= 20 ? .systemOrange : .systemGreen
        }

        switch controller.dashboardStatus {
        case .empty, .refreshing:
            return .secondaryLabelColor
        case .needsLogin, .mixedAttention:
            return .systemOrange
        case .failed:
            return .systemRed
        case .ready:
            return .systemGreen
        }
    }

    private func statusImage(named systemName: String, color: NSColor) -> NSImage? {
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
