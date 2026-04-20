import SwiftUI

struct ProfileManagerWindowView: View {
    @Bindable var controller: PlusProfileController
    let currentTime: AppMinuteClock
    @Environment(\.displayScale) private var displayScale
    @State private var isSessionExpanded = false
    @State private var windowChromeMetrics = WindowChromeMetrics()
    @State private var webViewReloadToken = UUID()

    init(
        controller: PlusProfileController,
        currentTime: AppMinuteClock,
        initialSessionExpanded: Bool = false
    ) {
        self.controller = controller
        self.currentTime = currentTime
        _isSessionExpanded = State(initialValue: initialSessionExpanded)
    }

    var body: some View {
        let seamOverlap = 1 / max(displayScale, 1)

        VStack(spacing: 0) {
            AccountWindowTitleBarGlass(
                height: windowChromeMetrics.titleBarObscuredHeight,
                seamOverlap: seamOverlap
            )

            AccountWindowBodyShell(seamOverlap: seamOverlap) {
                VStack(alignment: .leading, spacing: CodexTheme.sectionSpacing) {
                    header

                    if let message = controller.statusMessage {
                        CodexStatusBanner(
                            title: controller.dashboardStatus.title,
                            message: message,
                            tone: controller.dashboardStatus.tone,
                            symbolName: controller.dashboardStatus.symbolName
                        )
                    }

                    bodyContent
                }
                .padding(.top, CodexTheme.chromePadding)
                .padding(.horizontal, CodexTheme.chromePadding)
                .padding(.bottom, CodexTheme.chromePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1080, minHeight: 760)
        .background(Color.clear)
        .overlay(alignment: .topLeading) {
            WindowChromeMetricsReader(metrics: $windowChromeMetrics)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .onChange(of: controller.selectedProfileID) { _, _ in
            webViewReloadToken = UUID()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CodexPlusBar")
                    .font(.codexMicro)
                    .foregroundStyle(CodexTheme.supportText)
                    .kerning(1.4)

                Text("Profile Manager")
                    .font(.codexDisplayTitle)
                    .foregroundStyle(CodexTheme.primaryText)

                Text(headerMetaText)
                    .font(.codexBody)
                    .foregroundStyle(CodexTheme.mutedText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 10) {
                    CodexStatusBadge(
                        title: controller.dashboardStatus.title,
                        tone: controller.dashboardStatus.tone
                    )

                    if controller.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(CodexTheme.accentOrange)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: refreshAll) {
                        Label("Refresh all", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CodexPrimaryButtonStyle())
                    .disabled(controller.isRefreshing || controller.profiles.isEmpty)

                    Button(action: addProfile) {
                        Label("Add profile", systemImage: "plus")
                    }
                    .buttonStyle(CodexSecondaryButtonStyle())
                }
            }
        }
    }

    private var bodyContent: some View {
        HStack(alignment: .top, spacing: CodexTheme.contentSpacing) {
            sidebar
                .frame(width: 280, alignment: .topLeading)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        CodexCard(tier: .regular) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Saved profiles")
                            .font(.codexBodyStrong)
                            .foregroundStyle(CodexTheme.primaryText)

                        Text("One WebKit store per email account.")
                            .font(.codexCaption)
                            .foregroundStyle(CodexTheme.mutedText)
                    }

                    Spacer(minLength: 0)

                    Button(action: addProfile) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(CodexSecondaryButtonStyle())
                }

                if controller.profiles.isEmpty {
                    Text("Add a profile, then sign in with one email account at a time.")
                        .font(.codexSmall)
                        .foregroundStyle(CodexTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(controller.profiles) { snapshot in
                                Button {
                                    controller.selectProfile(id: snapshot.id)
                                } label: {
                                    SidebarProfileRow(
                                        snapshot: snapshot,
                                        isSelected: snapshot.id == controller.selectedProfileID
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let snapshot = controller.selectedProfile {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: CodexTheme.contentSpacing) {
                    detailHeader(for: snapshot)
                    usagePanel(for: snapshot)
                    actionPanel(for: snapshot)
                    webViewPanel(for: snapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, CodexTheme.contentSpacing)
            }
        } else {
            CodexCard(tier: .strong) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a profile")
                        .font(.codexBodyStrong)
                        .foregroundStyle(CodexTheme.primaryText)

                    Text("Pick a profile from the left to inspect usage, repair login, or remove it.")
                        .font(.codexSmall)
                        .foregroundStyle(CodexTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func detailHeader(for snapshot: PlusProfileSnapshot) -> some View {
        CodexCard(tier: .strong, accent: detailAccent(for: snapshot)) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        profileField(
                            title: "Profile label",
                            placeholder: "Email or label",
                            text: labelBinding(for: snapshot.id)
                        )

                        profileField(
                            title: "Email link",
                            placeholder: "https://mail.google.com",
                            text: emailLinkBinding(for: snapshot.id)
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        CodexStatusBadge(
                            title: snapshot.state.title,
                            tone: snapshot.state.tone
                        )

                        if snapshot.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(CodexTheme.accentOrange)
                        }
                    }
                }

                if let note = snapshot.note {
                    Text(note)
                        .font(.codexSmall)
                        .foregroundStyle(CodexTheme.supportText)
                }

                Text(detailSummary(for: snapshot))
                    .font(.codexSmall)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profileField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.codexCaption)
                .foregroundStyle(CodexTheme.supportText)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(
                        cornerRadius: CodexTheme.fieldCornerRadius,
                        style: .continuous
                    )
                    .fill(CodexTheme.surfaceFill(for: .nested))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: CodexTheme.fieldCornerRadius,
                            style: .continuous
                        )
                        .stroke(CodexTheme.surfaceBorder(for: .nested), lineWidth: 1)
                    }
                )
                .foregroundStyle(CodexTheme.primaryText)
        }
    }

    private func usagePanel(for snapshot: PlusProfileSnapshot) -> some View {
        CodexCard(tier: .regular) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Usage")
                    .font(.codexBodyStrong)
                    .foregroundStyle(CodexTheme.primaryText)

                if let usage = snapshot.usage {
                    HStack(spacing: 14) {
                        LargeUsageMetricCard(
                            title: "5-hour window",
                            value: snapshot.fiveHourText,
                            subtitle: "Resets in \(usage.primaryWindow.resetDescription(referenceDate: currentTime.now))",
                            accent: usage.fiveHourRemainingPercent <= 20
                                ? CodexTheme.accentOrange
                                : CodexTheme.accentGreen
                        )

                        LargeUsageMetricCard(
                            title: "7-day window",
                            value: snapshot.sevenDayText,
                            subtitle: usage.secondaryWindow.map {
                                "Resets in \($0.resetDescription(referenceDate: currentTime.now))"
                            } ?? "Window unavailable",
                            accent: CodexTheme.accentAqua
                        )
                    }
                } else {
                    Text(snapshot.statusMessage ?? "Live usage will appear here after a successful refresh.")
                        .font(.codexSmall)
                        .foregroundStyle(snapshot.state.tone.foregroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionPanel(for snapshot: PlusProfileSnapshot) -> some View {
        CodexCard(tier: .regular) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Actions")
                    .font(.codexBodyStrong)
                    .foregroundStyle(CodexTheme.primaryText)

                HStack(spacing: 10) {
                    Button(action: {
                        refreshProfile(snapshot.id)
                    }) {
                        Label("Refresh profile", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CodexPrimaryButtonStyle())
                    .disabled(snapshot.isRefreshing)

                    Button(action: reloadSelectedWebView) {
                        Label("Reload login view", systemImage: "safari")
                    }
                    .buttonStyle(CodexSecondaryButtonStyle())

                    Button(action: {
                        clearSession(snapshot.id)
                    }) {
                        Label("Clear session", systemImage: "xmark.circle")
                    }
                    .buttonStyle(CodexDangerButtonStyle())
                }

                HStack(spacing: 10) {
                    Button("Move up") {
                        controller.selectProfile(id: snapshot.id)
                        controller.moveSelectedProfileUp()
                    }
                    .buttonStyle(CodexSecondaryButtonStyle())

                    Button("Move down") {
                        controller.selectProfile(id: snapshot.id)
                        controller.moveSelectedProfileDown()
                    }
                    .buttonStyle(CodexSecondaryButtonStyle())

                    Button("Remove profile") {
                        removeProfile(snapshot.id)
                    }
                    .buttonStyle(CodexDangerButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func webViewPanel(for snapshot: PlusProfileSnapshot) -> some View {
        if let dataStore = controller.dataStore(for: snapshot.id) {
            CodexCard(tier: .strong) {
                VStack(alignment: .leading, spacing: isSessionExpanded ? 12 : 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sign in / repair session")
                                .font(.codexBodyStrong)
                                .foregroundStyle(CodexTheme.primaryText)

                            Text(sessionSummaryText(for: snapshot))
                                .font(.codexSmall)
                                .foregroundStyle(CodexTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Button(isSessionExpanded ? "Hide session" : "Show session") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSessionExpanded.toggle()
                            }
                        }
                        .buttonStyle(CodexSecondaryButtonStyle())
                    }

                    if isSessionExpanded {
                        CodexCard(tier: .subtle, padding: 8, shadow: false) {
                            ProfileSignInWebView(dataStore: dataStore)
                                .id("\(snapshot.id.uuidString)-\(webViewReloadToken.uuidString)")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: CodexTheme.fieldCornerRadius - 1,
                                        style: .continuous
                                    )
                                )
                        }
                        .frame(minHeight: 360, idealHeight: 420, maxHeight: 520)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headerMetaText: String {
        let count = controller.profiles.count
        let countLabel = count == 1 ? "1 saved profile" : "\(count) saved profiles"

        if let refreshedAt = controller.profiles.compactMap(\.lastRefreshAt).max(),
           let updatedText = DisplayFormatter.updatedText(refreshedAt, referenceDate: currentTime.now) {
            return "\(updatedText) · \(countLabel)"
        }

        return count == 0 ? "Add your first profile to begin" : countLabel
    }

    private func detailSummary(for snapshot: PlusProfileSnapshot) -> String {
        if let updatedText = DisplayFormatter.updatedText(snapshot.lastRefreshAt, referenceDate: currentTime.now) {
            return updatedText
        }

        switch snapshot.state {
        case .idle:
            return "Ready for first login or first refresh."
        case .loading:
            return "Loading live usage for this profile."
        case .ready:
            return "Live usage is loaded."
        case .needsLogin:
            return "This profile needs a fresh ChatGPT login."
        case .failed:
            return snapshot.statusMessage ?? "The last refresh failed."
        }
    }

    private func detailAccent(for snapshot: PlusProfileSnapshot) -> Color? {
        if let remaining = snapshot.usage?.fiveHourRemainingPercent {
            if remaining <= 20 {
                return CodexTheme.accentOrange
            }

            return remaining <= 40 ? CodexTheme.accentYellow : CodexTheme.accentGreen
        }

        return snapshot.state == .ready ? nil : snapshot.state.tone.foregroundColor
    }

    private func sessionSummaryText(for snapshot: PlusProfileSnapshot) -> String {
        switch snapshot.state {
        case .idle:
            return isSessionExpanded
                ? "Sign in with this profile in its own cookie store."
                : "Hidden until you need to sign in."
        case .loading:
            return isSessionExpanded
                ? "This profile is refreshing while the session view stays open."
                : "Hidden while this profile refreshes."
        case .ready:
            return isSessionExpanded
                ? "This profile session view is open."
                : "Hidden until you need to repair this session."
        case .needsLogin:
            return isSessionExpanded
                ? "Sign in again to repair this profile."
                : "Open the session view to sign in again."
        case .failed:
            return snapshot.statusMessage ?? "Open the session view to inspect this profile."
        }
    }

    private func labelBinding(for profileID: UUID) -> Binding<String> {
        Binding(
            get: {
                controller.profiles.first(where: { $0.id == profileID })?.profile.label ?? ""
            },
            set: { newValue in
                controller.updateLabel(for: profileID, label: newValue)
            }
        )
    }

    private func emailLinkBinding(for profileID: UUID) -> Binding<String> {
        Binding(
            get: {
                controller.profiles.first(where: { $0.id == profileID })?.profile.emailLink ?? ""
            },
            set: { newValue in
                controller.updateEmailLink(for: profileID, link: newValue)
            }
        )
    }

    private func refreshAll() {
        Task {
            await controller.refreshAll()
        }
    }

    private func refreshProfile(_ profileID: UUID) {
        Task {
            await controller.refreshProfile(id: profileID)
        }
    }

    private func addProfile() {
        controller.addProfile()
    }

    private func clearSession(_ profileID: UUID) {
        Task {
            await controller.clearSession(for: profileID)
            reloadSelectedWebView()
        }
    }

    private func removeProfile(_ profileID: UUID) {
        Task {
            await controller.removeProfile(id: profileID)
            reloadSelectedWebView()
        }
    }

    private func reloadSelectedWebView() {
        webViewReloadToken = UUID()
    }
}

private struct SidebarProfileRow: View {
    let snapshot: PlusProfileSnapshot
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.label)
                    .font(.codexSmallStrong)
                    .foregroundStyle(CodexTheme.primaryText)
                    .lineLimit(1)

                Text(snapshot.note ?? snapshot.state.title)
                    .font(.codexCaption)
                    .foregroundStyle(CodexTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(snapshot.fiveHourText)
                .font(.codexSmallStrong)
                .monospacedDigit()
                .foregroundStyle(snapshot.state.tone.foregroundColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                .fill(isSelected ? CodexTheme.surfaceFill(for: .strong) : CodexTheme.surfaceFill(for: .nested))
                .overlay {
                    RoundedRectangle(cornerRadius: CodexTheme.fieldCornerRadius, style: .continuous)
                        .stroke(
                            isSelected
                                ? CodexTheme.accentOrange.opacity(0.35)
                                : CodexTheme.surfaceBorder(for: .nested),
                            lineWidth: 1
                        )
                }
        )
    }
}

private struct LargeUsageMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let accent: Color

    var body: some View {
        CodexCard(tier: .nested, accent: accent, shadow: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.codexCaption)
                    .foregroundStyle(CodexTheme.supportText)

                Text(value)
                    .font(.codexDisplayTitle)
                    .foregroundStyle(accent)
                    .monospacedDigit()

                Text(subtitle)
                    .font(.codexSmall)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountWindowTitleBarGlass: View {
    let height: CGFloat
    let seamOverlap: CGFloat

    private var warmTintGradient: LinearGradient {
        LinearGradient(
            colors: [
                CodexTheme.Palette.bg1.color(alpha: 0.02),
                CodexTheme.Palette.bg0.color(alpha: 0.07),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var shape: some Shape {
        AccountWindowTitleBarGlassShape(cornerRadius: CodexTheme.shellCornerRadius)
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                Group {
                    if #available(macOS 26.0, *) {
                        Rectangle()
                            .fill(.clear)
                            .glassEffect(
                                Glass.clear.tint(CodexTheme.Palette.bg2.color(alpha: 0.035)),
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

private struct AccountWindowTitleBarGlassShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        if #available(macOS 14.0, *) {
            return UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
            .path(in: rect)
        } else {
            return legacyPath(in: rect)
        }
    }

    private func legacyPath(in rect: CGRect) -> Path {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: minX + radius, y: minY),
            control: CGPoint(x: minX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addQuadCurve(
            to: CGPoint(x: maxX, y: minY + radius),
            control: CGPoint(x: maxX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX, y: maxY))
        path.closeSubpath()
        return path
    }
}

private struct AccountWindowBodyShell<Content: View>: View {
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
        let shellShape = AccountWindowBodyMask(cornerRadius: CodexTheme.shellCornerRadius)
        let borderShape = AccountWindowBodyBorderShape(cornerRadius: CodexTheme.shellCornerRadius)

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

private struct AccountWindowBodyMask: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        if #available(macOS 14.0, *) {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .path(in: rect)
        } else {
            return legacyPath(in: rect)
        }
    }

    private func legacyPath(in rect: CGRect) -> Path {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: maxX - radius, y: maxY),
            control: CGPoint(x: maxX, y: maxY)
        )
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: minX, y: maxY - radius),
            control: CGPoint(x: minX, y: maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct AccountWindowBodyBorderShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        legacyPath(in: rect)
    }

    private func legacyPath(in rect: CGRect) -> Path {
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
