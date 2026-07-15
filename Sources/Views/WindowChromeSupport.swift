import AppKit
import SwiftUI

struct WindowChromeMetrics: Equatable {
    var titleBarObscuredHeight: CGFloat = 56
}

struct CodexWindowChromeContainer<Content: View>: View {
    @Environment(\.displayScale) private var displayScale
    @State private var metrics = WindowChromeMetrics()

    let minimumSize: CGSize
    let content: Content

    init(
        minimumSize: CGSize,
        @ViewBuilder content: () -> Content
    ) {
        self.minimumSize = minimumSize
        self.content = content()
    }

    var body: some View {
        let seamOverlap = 1 / max(displayScale, 1)

        VStack(spacing: 0) {
            CodexWindowTitleBarGlass(
                height: metrics.titleBarObscuredHeight,
                seamOverlap: seamOverlap
            )

            CodexWindowBodyShell(seamOverlap: seamOverlap) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: minimumSize.width,
            minHeight: minimumSize.height
        )
        .background(Color.clear)
        .overlay(alignment: .topLeading) {
            WindowChromeMetricsReader(metrics: $metrics)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .codexThemeRefreshScope()
    }
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
        Task { @MainActor [weak self] in
            await Task.yield()
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

struct CodexWindowTitleBarGlass: View {
    let height: CGFloat
    let seamOverlap: CGFloat

    private var warmTintGradient: LinearGradient {
        let palette = CodexTheme.activePalette

        return LinearGradient(
            colors: [
                palette.bg1.color(alpha: palette.isDark ? 0.02 : 0.10),
                palette.bgDim.color(alpha: palette.isDark ? 0.07 : 0.18),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var shape: some Shape {
        CodexWindowTitleBarGlassShape(cornerRadius: CodexTheme.shellCornerRadius)
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                Group {
                    if #available(macOS 26.0, *) {
                        Rectangle()
                            .fill(.clear)
                            .glassEffect(
                                Glass.clear.tint(CodexTheme.activePalette.bg1.color(alpha: CodexTheme.isDarkTheme ? 0.035 : 0.10)),
                                in: shape
                            )
                            .overlay {
                                warmTintGradient
                            }
                    } else {
                        WindowTitleBarVisualEffectView()
                            .overlay {
                                warmTintGradient
                            }
                    }
                }
                .clipShape(shape)
                .frame(maxWidth: .infinity)
                .frame(height: height + seamOverlap)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

private struct CodexWindowTitleBarGlassShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )
        .path(in: rect)
    }
}

private struct CodexWindowBodyShell<Content: View>: View {
    let seamOverlap: CGFloat
    let content: Content

    init(
        seamOverlap: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.seamOverlap = seamOverlap
        self.content = content()
    }

    var body: some View {
        let shadow = CodexTheme.shadow(for: .strong)
        let shellShape = CodexWindowBodyMask(cornerRadius: CodexTheme.shellCornerRadius)
        let borderShape = CodexWindowBodyBorderShape(cornerRadius: CodexTheme.shellCornerRadius)

        GeometryReader { proxy in
            let bodyHeight = proxy.size.height + seamOverlap

            ZStack(alignment: .topLeading) {
                shellShape
                    .fill(Color.black.opacity(0.018))
                    .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 12)
                            Rectangle()
                                .fill(Color.white)
                        }
                    }

                CodexBackdrop()
                    .mask(shellShape)

                Rectangle()
                    .fill(CodexTheme.shellFill(for: .dialog))
                    .mask(shellShape)
                    .overlay {
                        Rectangle()
                            .fill(CodexTheme.surfaceSheen(for: .strong))
                            .mask(shellShape)
                    }
                    .overlay {
                        borderShape
                            .stroke(CodexTheme.surfaceBorder(for: .strong), lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        content
                            .frame(
                                width: proxy.size.width,
                                height: bodyHeight,
                                alignment: .topLeading
                            )
                    }
            }
            .frame(width: proxy.size.width, height: bodyHeight, alignment: .topLeading)
            .offset(y: -seamOverlap)
            .clipped()
        }
    }
}

private struct CodexWindowBodyMask: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .path(in: rect)
    }
}

private struct CodexWindowBodyBorderShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        let minX = rect.minX + 0.5
        let maxX = rect.maxX - 0.5
        let minY = rect.minY + 0.5
        let maxY = rect.maxY - 0.5

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: minX, y: maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: minX + radius, y: maxY),
            control: CGPoint(x: minX, y: maxY)
        )
        path.addLine(to: CGPoint(x: maxX - radius, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: maxX, y: maxY - radius),
            control: CGPoint(x: maxX, y: maxY)
        )
        path.addLine(to: CGPoint(x: maxX, y: minY))
        return path
    }
}
