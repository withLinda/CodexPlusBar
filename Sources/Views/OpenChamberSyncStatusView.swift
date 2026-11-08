import SwiftUI

struct OpenChamberSyncStatusView: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    @AppStorage(OpenChamberSyncPreference.enabledKey) private var enabled = OpenChamberSyncPreference.defaultEnabled
    let message: String
    let isSyncing: Bool
    let syncNow: () -> Void
    var checkMessage: String? = nil
    var checkProgress: OpenChamberSignInCheckProgress? = nil
    var repairCount: Int = 0
    var canCheck: Bool = false
    var isBusy: Bool = false
    var checkSignIns: () -> Void = {}
    var cancelCheck: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if repairCount > 0 {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(CodexStatusTone.critical.foregroundColor)
                    .accessibilityHidden(true)
            }
            Text(checkMessage ?? (enabled ? message : "OpenChamber automatic sync is off."))
                .font(ProfileManagerTypography.small)
                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).supportText.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .monospacedDigit()
                .help(checkMessage == nil ? message : "Checks saved OpenChamber sign-ins. Highlighted accounts need sign-in; not checked means verification could not finish. \(message)")
            Button(checkProgress == nil ? "Check sign-ins" : "Cancel", systemImage: checkProgress == nil ? "checkmark.shield" : "xmark") {
                if checkProgress == nil { checkSignIns() } else { cancelCheck() }
            }
            .buttonStyle(CodexQuietButtonStyle())
            .disabled(checkProgress == nil && !canCheck)
            .fixedSize()
            .accessibilityLabel(checkProgress == nil ? "Check all OpenChamber sign-ins" : "Cancel sign-in check")
            .help("Verify every saved OpenChamber sign-in without switching accounts.")
            Button("Sync now", systemImage: "arrow.triangle.2.circlepath", action: syncNow)
                .buttonStyle(CodexQuietButtonStyle())
                .disabled(!enabled || isSyncing || isBusy || checkProgress != nil)
                .fixedSize()
                .accessibilityLabel("Sync OpenChamber now")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenChamber account sync")
    }
}
