import SwiftUI

struct CloudSessionInboxSection: View {
    let presentation: any CloudSyncPresenting
    let profileID: UUID
    var body: some View {
        CodexCard(tier: .regular, shadow: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Saved sessions from iCloud").font(ProfileManagerTypography.bodyStrong)
                    Spacer(minLength: 8)
                    Button("Reload") { Task { await presentation.reload() } }
                        .disabled(presentation.busy)
                }
                if presentation.sessions.isEmpty {
                    Text(presentation.enabled && presentation.includesSessions
                        ? "No saved sessions available from another Mac."
                        : "Enable iCloud Sync and saved login sessions in Settings to see sessions from other Macs.")
                        .foregroundStyle(CodexTheme.mutedText)
                }
                ForEach(presentation.sessions, id: \.recordName) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(session.kind.displayName) · \(session.sourceName)")
                            .font(ProfileManagerTypography.smallStrong)
                        Text("\(session.capturedAt.formatted(date: .abbreviated, time: .shortened)) · revision \(session.revision)")
                            .foregroundStyle(CodexTheme.mutedText)
                        Button("Import saved session") { Task { try? await presentation.adopt(session) } }
                            .disabled(!presentation.canAdopt(session))
                            .accessibilityLabel("Import \(session.kind.displayName) saved session from \(session.sourceName)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = presentation.sessionMessage { Text(message).foregroundStyle(CodexTheme.mutedText) }
                if let failure = presentation.failure {
                    Text(failure.message).foregroundStyle(CodexTheme.mutedText)
                    if presentation.canRetry {
                        Button("Retry import") { Task { try? await presentation.retry() } }
                    }
                }
                if presentation.busy { ProgressView("Preparing saved session…").controlSize(.small) }
            }
            .font(ProfileManagerTypography.small)
            .buttonStyle(CodexSecondaryButtonStyle())
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: profileID) { await presentation.selectProfile(profileID) }
        .task(id: presentation.epoch) { await presentation.selectProfile(profileID) }
    }
}

extension CloudSessionKind {
    var displayName: String {
        switch self { case .browser: "Browser"; case .desktop: "Codex"; case .openChamber: "OpenChamber" }
    }
}
