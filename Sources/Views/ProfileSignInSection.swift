import SwiftUI

/// Both app sign-ins share one quiet surface and the same action anchors.
struct ProfileSignInSection: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let desktopSaved: Bool
    let openChamberSaved: Bool
    let desktopWorking: Bool
    let openChamberWorking: Bool
    let desktopStatus: OpenChamberActionStatus?
    let openChamberStatus: OpenChamberActionStatus?
    let saveDesktop: () -> Void
    let switchDesktop: () -> Void
    let saveOpenChamber: () -> Void
    let switchOpenChamber: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProfileAppSignInRow(title: "ChatGPT / Codex", switchTitle: "Switch and open",
                                hasSavedSignIn: desktopSaved, isWorking: desktopWorking,
                                status: desktopStatus,
                                saveHelp: "Sign in to this account in the desktop app first, then save its current sign-in.",
                                switchHelp: "Verify this saved sign-in, close the desktop app, and reopen it with this account.",
                                save: saveDesktop, switchAccount: switchDesktop)
            ProfileAppSignInRow(title: "OpenChamber", switchTitle: "Switch",
                                hasSavedSignIn: openChamberSaved, isWorking: openChamberWorking,
                                status: openChamberStatus,
                                saveHelp: "Sign in to this account in OpenChamber first, then save its current OpenAI sign-in.",
                                switchHelp: "Verify and switch the local OpenAI connection for new requests.",
                                save: saveOpenChamber, switchAccount: switchOpenChamber)
        }
        .padding(12)
        .background(CodexTheme.surfaceToken(for: .subtle, preset: themeContext.preset).color,
                    in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved app sign-ins")
    }
}

private struct ProfileAppSignInRow: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let title: String
    let switchTitle: String
    let hasSavedSignIn: Bool
    let isWorking: Bool
    let status: OpenChamberActionStatus?
    let saveHelp: String
    let switchHelp: String
    let save: () -> Void
    let switchAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    identity.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    actions.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    HStack { Spacer(minLength: 0); actions }
                }
            }
            if let status {
                Label(status.message, systemImage: statusSymbol(status.tone))
                    .font(.system(size: 13))
                    .foregroundStyle(CodexTheme.statusForegroundToken(for: status.tone, preset: themeContext.preset).color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(title)-sign-in-feedback")
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) sign-in")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).strongText.color)
            Label(hasSavedSignIn ? "Sign-in saved" : "No saved sign-in",
                  systemImage: hasSavedSignIn ? "checkmark.circle" : "circle.dashed")
                .font(.system(size: 13))
                .foregroundStyle(CodexTheme.palette(for: themeContext.preset).supportText.color)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Save current sign-in", action: save)
                .buttonStyle(CodexQuietButtonStyle(font: .system(size: 13), horizontalPadding: 10))
                .disabled(isWorking)
                .accessibilityLabel("Save current \(title) sign-in")
                .help(saveHelp)
            Button(action: switchAccount) {
                Label(switchTitle, systemImage: "arrow.triangle.2.circlepath")
                    .frame(minWidth: 128)
            }
            .buttonStyle(CodexSecondaryButtonStyle(font: .system(size: 13, weight: .semibold),
                                                  foregroundColor: CodexTheme.utilityActionTextToken(preset: themeContext.preset).color,
                                                  horizontalPadding: 10))
            .disabled(!hasSavedSignIn || isWorking)
            .accessibilityLabel("\(switchTitle) \(title)")
            .help(switchHelp)
        }
    }

    private func statusSymbol(_ tone: CodexStatusTone) -> String {
        switch tone {
        case .success: "checkmark.circle"
        case .critical, .warning: "exclamationmark.circle"
        case .neutral, .info: "info.circle"
        }
    }
}
