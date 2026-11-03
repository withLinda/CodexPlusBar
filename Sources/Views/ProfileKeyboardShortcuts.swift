import AppKit
import SwiftUI

enum ProfileKeyboardAction: Equatable {
    case zoomIn, zoomOut, resetZoom, previousProfile, nextProfile

    @MainActor
    static func resolve(_ event: NSEvent, firstResponder: NSResponder?) -> Self? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command || modifiers == [.command, .shift] {
            let characters = event.charactersIgnoringModifiers ?? ""
            if characters == "+" || characters == "=" { return .zoomIn }
            if modifiers == .command {
                if characters == "-" { return .zoomOut }
                if characters == "0" { return .resetZoom }
            }
        }
        guard modifiers.isEmpty,
              !(firstResponder is NSText),
              !(firstResponder is NSControl) else { return nil }
        switch event.keyCode {
        case 126: return .previousProfile
        case 125: return .nextProfile
        default: return nil
        }
    }
}

/// These screens are hosted by AppKit, outside a SwiftUI Window scene. Route
/// shortcuts only to the owning key window, without taking focus from editors.
struct ProfileKeyboardShortcuts: NSViewRepresentable {
    var isEnabled = true
    let handle: (ProfileKeyboardAction) -> Bool

    func makeNSView(context: Context) -> ProfileKeyboardView { ProfileKeyboardView() }

    func updateNSView(_ view: ProfileKeyboardView, context: Context) {
        view.handle = isEnabled ? handle : nil
    }

    static func dismantleNSView(_ view: ProfileKeyboardView, coordinator: ()) {
        view.stopMonitoring()
        view.handle = nil
    }
}

final class ProfileKeyboardView: NSView {
    var handle: ((ProfileKeyboardAction) -> Bool)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local event monitors are called synchronously on the main thread.
            let handled = MainActor.assumeIsolated { self?.handleEvent(event) == true }
            return handled ? nil : event
        }
    }

    func handleEvent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !isHiddenOrHasHiddenAncestor,
              let action = ProfileKeyboardAction.resolve(event, firstResponder: window.firstResponder)
        else { return false }
        return handle?(action) ?? false
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Scale both layout and typography. Measure the logical viewport before
/// scaling so hit targets and scroll extents stay aligned with their drawing.
struct ProfileContentZoom<Content: View>: View {
    let scale: Double
    let minimumWidth: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            let factor = CGFloat(scale)
            let width = max(geometry.size.width / factor, minimumWidth)
            ScrollView(.horizontal) {
                content
                    .frame(width: width, height: geometry.size.height / factor, alignment: .topLeading)
                    .scaleEffect(factor, anchor: .topLeading)
                    .frame(width: width * factor, height: geometry.size.height, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background {
            ProfileZoomWindowSizing(minimumWidth: minimumWidth * max(1, scale))
                .frame(width: 0, height: 0)
        }
    }
}

private struct ProfileZoomWindowSizing: NSViewRepresentable {
    let minimumWidth: CGFloat

    func makeNSView(context: Context) -> ProfileZoomWindowProbe { ProfileZoomWindowProbe() }

    func updateNSView(_ view: ProfileZoomWindowProbe, context: Context) {
        view.minimumWidth = minimumWidth
        view.scheduleResize()
    }

    static func dismantleNSView(_ view: ProfileZoomWindowProbe, coordinator: ()) {
        view.stopObserving()
    }
}

private final class ProfileZoomWindowProbe: NSView {
    var minimumWidth: CGFloat = 900
    private var screenObservers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        for (name, object) in [
            (NSWindow.didChangeScreenNotification, window as AnyObject?),
            (NSApplication.didChangeScreenParametersNotification, nil),
        ] {
            screenObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleResize() }
            })
        }
        scheduleResize()
    }

    func stopObserving() {
        screenObservers.forEach(NotificationCenter.default.removeObserver)
        screenObservers.removeAll()
    }

    func scheduleResize() {
        Task { @MainActor [weak self] in
            guard let self, let window, let screen = window.screen,
                  !window.styleMask.contains(.fullScreen) else { return }
            let width = min(minimumWidth, screen.visibleFrame.width)
            window.minSize.width = width
            guard window.frame.width < width else { return }
            var frame = window.frame
            frame.size.width = width
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - width))
            window.setFrame(frame, display: true)
        }
    }
}
