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
                        ProfileManagerStatusBanner(
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
                    .font(ProfileManagerTypography.micro)
                    .foregroundStyle(CodexTheme.supportText)
                    .kerning(1.4)

                Text("Profile Manager")
                    .font(ProfileManagerTypography.title)
                    .foregroundStyle(CodexTheme.primaryText)

                Text(headerMetaText)
                    .font(ProfileManagerTypography.body)
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
                    .buttonStyle(ProfileManagerPrimaryButtonStyle())
                    .disabled(controller.isRefreshing || controller.profiles.isEmpty)

                    Button(action: addProfile) {
                        Label("Add profile", systemImage: "plus")
                    }
                    .buttonStyle(ProfileManagerSecondaryButtonStyle())
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
                            .font(ProfileManagerTypography.bodyStrong)
                            .foregroundStyle(CodexTheme.primaryText)

                        Text("One WebKit store per email account.")
                            .font(ProfileManagerTypography.caption)
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
                        .font(ProfileManagerTypography.small)
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
                                    ProfileSummaryRow(
                                        snapshot: snapshot,
                                        referenceDate: currentTime.now,
                                        mode: .sidebar(
                                            isSelected: snapshot.id == controller.selectedProfileID
                                        )
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
                        .font(ProfileManagerTypography.bodyStrong)
                        .foregroundStyle(CodexTheme.primaryText)

                    Text("Pick a profile from the left to inspect usage, repair login, or remove it.")
                        .font(ProfileManagerTypography.small)
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
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.supportText)
                }

                Text(detailSummary(for: snapshot))
                    .font(ProfileManagerTypography.small)
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
                .font(ProfileManagerTypography.caption)
                .foregroundStyle(CodexTheme.supportText)

            TextField(placeholder, text: text)
                .font(ProfileManagerTypography.body)
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
                    .font(ProfileManagerTypography.bodyStrong)
                    .foregroundStyle(CodexTheme.primaryText)

                if let usageSummary = snapshot.usageSummary(referenceDate: currentTime.now) {
                    HStack(spacing: 12) {
                        ProfileUsageMetricBlock(
                            summary: usageSummary.primary,
                            density: .expanded
                        )

                        ProfileUsageMetricBlock(
                            summary: usageSummary.secondary,
                            density: .expanded
                        )
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Usage windows")
                    .accessibilityValue(usageSummary.accessibilityValue)
                } else {
                    Text(snapshot.statusMessage ?? "Live usage will appear here after a successful refresh.")
                        .font(ProfileManagerTypography.small)
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
                    .font(ProfileManagerTypography.bodyStrong)
                    .foregroundStyle(CodexTheme.primaryText)

                HStack(spacing: 10) {
                    Button(action: {
                        refreshProfile(snapshot.id)
                    }) {
                        Label("Refresh profile", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ProfileManagerPrimaryButtonStyle())
                    .disabled(snapshot.isRefreshing)

                    Button(action: reloadSelectedWebView) {
                        Label("Reload login view", systemImage: "safari")
                    }
                    .buttonStyle(ProfileManagerSecondaryButtonStyle())

                    Button(action: {
                        clearSession(snapshot.id)
                    }) {
                        Label("Clear session", systemImage: "xmark.circle")
                    }
                    .buttonStyle(ProfileManagerDangerButtonStyle())
                }

                HStack(spacing: 10) {
                    Button("Move up") {
                        controller.selectProfile(id: snapshot.id)
                        controller.moveSelectedProfileUp()
                    }
                    .buttonStyle(ProfileManagerSecondaryButtonStyle())

                    Button("Move down") {
                        controller.selectProfile(id: snapshot.id)
                        controller.moveSelectedProfileDown()
                    }
                    .buttonStyle(ProfileManagerSecondaryButtonStyle())

                    Button("Remove profile") {
                        removeProfile(snapshot.id)
                    }
                    .buttonStyle(ProfileManagerDangerButtonStyle())
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
                                .font(ProfileManagerTypography.bodyStrong)
                                .foregroundStyle(CodexTheme.primaryText)

                            Text(sessionSummaryText(for: snapshot))
                                .font(ProfileManagerTypography.small)
                                .foregroundStyle(CodexTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Button(isSessionExpanded ? "Hide session" : "Show session") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSessionExpanded.toggle()
                            }
                        }
                        .buttonStyle(ProfileManagerSecondaryButtonStyle())
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
            return CodexTheme.usagePercentageColor(forRemainingPercent: remaining)
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

private struct ProfileManagerStatusBanner: View {
    let title: String
    let message: String
    let tone: CodexStatusTone
    let symbolName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.Radius.badge, style: .continuous)
                            .stroke(tone.borderColor, lineWidth: 1)
                    )

                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone.foregroundColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: CodexTheme.Spacing.micro) {
                Text(title)
                    .font(ProfileManagerTypography.smallStrong)
                    .foregroundStyle(CodexTheme.primaryText)

                Text(message)
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(CodexTheme.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                .fill(CodexTheme.surfaceFill(for: .nested))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                        .fill(tone.backgroundColor.opacity(0.52))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.cornerRadius(for: .nested), style: .continuous)
                        .stroke(tone.borderColor, lineWidth: 1)
                )
        )
    }
}

private struct ProfileManagerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(CodexTheme.accentInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.accentGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .shadow(color: CodexTheme.accentOrange.opacity(0.20), radius: 12, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.46)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct ProfileManagerSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(CodexTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.surfaceFill(for: .subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                            .fill(CodexTheme.surfaceSheen(for: .subtle))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(CodexTheme.surfaceBorder(for: .subtle), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.46)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct ProfileManagerDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ProfileManagerTypography.smallStrong)
            .foregroundStyle(CodexTheme.accentRed)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .fill(CodexTheme.accentRed.opacity(configuration.isPressed ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.controlCornerRadius, style: .continuous)
                    .stroke(CodexTheme.accentRed.opacity(0.24), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.46)
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
