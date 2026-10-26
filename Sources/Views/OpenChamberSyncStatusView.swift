import SwiftUI

struct OpenChamberSyncStatusView: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    @AppStorage(OpenChamberSyncPreference.enabledKey) private var enabled = OpenChamberSyncPreference.defaultEnabled
    let message: String
    let isSyncing: Bool
    let syncNow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(enabled ? message : "OpenChamber automatic sync is off.")
                .font(ProfileManagerTypography.small)
                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).supportText.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Sync now", systemImage: "arrow.triangle.2.circlepath", action: syncNow)
                .buttonStyle(CodexQuietButtonStyle())
                .disabled(!enabled || isSyncing)
                .fixedSize()
                .accessibilityLabel("Sync OpenChamber now")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenChamber account sync")
    }
}
