import SwiftUI

struct CloudSyncSettingsSection: View {
    let presentation: any CloudSyncPresenting
    var body: some View {
        CodexCard(tier: .regular, shadow: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("iCloud Sync").font(ProfileManagerTypography.bodyStrong)
                Toggle("Sync accounts with iCloud", isOn: Binding(get: { presentation.enabled }, set: { value in
                    Task { await presentation.setEnabled(value) }
                }))
                .disabled(presentation.busy || presentation.isTransferring)
                Toggle("Include saved login sessions", isOn: Binding(get: { presentation.includesSessions }, set: { value in
                    Task { await presentation.setIncludesSessions(value) }
                }))
                .disabled(!presentation.enabled || presentation.busy || presentation.isTransferring)
                Text("Accounts, passwords and 2FA keys sync privately through iCloud. Saved logins are imported explicitly on each Mac; expiration or token rotation may require a fresh sign-in.")
                    .foregroundStyle(CodexTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center) {
                    Text(presentation.status.title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Sync Now") { Task { await presentation.syncNow() } }
                        .disabled(!presentation.canSyncNow)
                }
                if let message = presentation.statusMessage {
                    Text(message).foregroundStyle(CodexTheme.mutedText).fixedSize(horizontal: false, vertical: true)
                }
                if let date = presentation.lastSuccessfulSync {
                    Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(CodexTheme.mutedText)
                }
                if presentation.deliveryDegraded {
                    Text("Background notifications are unavailable. Sync continues when the app opens or you choose Sync Now.")
                        .foregroundStyle(CodexTheme.mutedText).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(ProfileManagerTypography.small)
            .toggleStyle(.checkbox)
            .buttonStyle(CodexSecondaryButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
