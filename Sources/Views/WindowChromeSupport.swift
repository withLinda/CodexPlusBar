import AppKit
import SwiftUI

struct WindowChromeMetrics: Equatable {
    var titleBarObscuredHeight: CGFloat = 56
}

struct WindowChromeMetricsReader: NSViewRepresentable {
    @Binding var metrics: WindowChromeMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator(metrics: $metrics)
    }

    func makeNSView(context: Context) -> WindowChromeProbeView {
        let view = WindowChromeProbeView()
        view.onMetricsChange = context.coordinator.handle
        view.scheduleMetricsUpdate()
        return view
    }

    func updateNSView(_ nsView: WindowChromeProbeView, context: Context) {
        nsView.onMetricsChange = context.coordinator.handle
        nsView.scheduleMetricsUpdate()
    }

    @MainActor
    final class Coordinator {
        @Binding private var metrics: WindowChromeMetrics
        private var lastMetrics: WindowChromeMetrics

        init(metrics: Binding<WindowChromeMetrics>) {
            _metrics = metrics
            lastMetrics = metrics.wrappedValue
        }

        func handle(_ newMetrics: WindowChromeMetrics) {
            guard newMetrics != lastMetrics else {
                return
            }

            lastMetrics = newMetrics
            metrics = newMetrics
        }
    }
}

struct WindowTitleBarVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> PassThroughVisualEffectView {
        let view = PassThroughVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: PassThroughVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: PassThroughVisualEffectView) {
        view.material = .titlebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}

final class PassThroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class WindowChromeProbeView: NSView {
    var onMetricsChange: (@MainActor (WindowChromeMetrics) -> Void)?

    private var observers: [Any] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebindWindowObservers()
        scheduleMetricsUpdate()
    }

    override func layout() {
        super.layout()
        publishMetrics()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleMetricsUpdate()
    }

    func scheduleMetricsUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.publishMetrics()
        }
    }

    private func publishMetrics() {
        guard let window else {
            return
        }

        let metrics = WindowChromeMetrics(
            titleBarObscuredHeight: max(window.frame.height - window.contentLayoutRect.maxY, 0)
        )
        onMetricsChange?(metrics)
    }

    private func rebindWindowObservers() {
        removeObservers()

        guard let window else {
            return
        }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didUpdateNotification,
        ]

        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.publishMetrics()
                }
            }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}
