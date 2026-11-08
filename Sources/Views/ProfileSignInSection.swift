import SwiftUI

struct ProfileSignInPresentation {
    let hasSavedSignIn: Bool
    let needsRepair: Bool

    var showsSave: Bool { !hasSavedSignIn || needsRepair }
    var statusText: String {
        if !hasSavedSignIn { return "No saved sign-in" }
        return needsRepair ? "Sign-in needs updating" : "Sign-in saved"
    }
    var statusSymbol: String {
        if !hasSavedSignIn { return "circle.dashed" }
        return needsRepair ? "exclamationmark.circle" : "checkmark.circle"
    }
}

/// Both app sign-ins share one quiet surface and the same action anchors.
struct ProfileSignInSection: View {
    @Environment(\.codexThemeRefreshContext) private var themeContext
    let desktopSaved: Bool
    let openChamberSaved: Bool
    let desktopNeedsRepair: Bool
    let openChamberNeedsRepair: Bool
    let desktopWorking: Bool
    let openChamberWorking: Bool
    let desktopStatus: OpenChamberActionStatus?
    let openChamberStatus: OpenChamberActionStatus?
    let saveDesktop: () -> Void
    let switchDesktop: () -> Void
    let saveOpenChamber: () -> Void
    let switchOpenChamber: () -> Void
    var repairProgress: AppSignInRepairProgress? = nil
    var repairStatus: OpenChamberActionStatus? = nil
    var canRepair: Bool = true
    var repairBoth: () -> Void = {}
    var cancelRepair: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProfileAppSignInRow(title: "ChatGPT / Codex", switchTitle: "Switch and open",
                                hasSavedSignIn: desktopSaved, isWorking: desktopWorking,
                                needsRepair: desktopNeedsRepair,
                                status: desktopStatus,
                                saveHelp: "Sign in to this account in the desktop app first, then save its current sign-in.",
                                switchHelp: "Verify this saved sign-in, close the desktop app, and reopen it with this account.",
                                save: saveDesktop, switchAccount: switchDesktop)
            ProfileAppSignInRow(title: "OpenChamber", switchTitle: "Switch",
                                hasSavedSignIn: openChamberSaved, isWorking: openChamberWorking,
                                needsRepair: openChamberNeedsRepair,
                                status: openChamberStatus,
                                saveHelp: "Sign in to this account in OpenChamber first, then save its current OpenAI sign-in.",
                                switchHelp: "Verify and switch the local OpenAI connection for new requests.",
                                 save: saveOpenChamber, switchAccount: switchOpenChamber)
            HStack(alignment: .center, spacing: 12) {
                if let message = repairProgress?.message ?? repairStatus?.message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(CodexTheme.statusForegroundToken(for: repairStatus?.tone ?? .info, preset: themeContext.preset).color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("app-sign-in-repair-status")
                }
                Spacer(minLength: 0)
                Button(repairProgress == nil ? "Repair both" : "Cancel",
                       systemImage: repairProgress == nil ? "arrow.triangle.2.circlepath" : "xmark") {
                    if repairProgress == nil { repairBoth() } else { cancelRepair() }
                }
                .buttonStyle(CodexQuietButtonStyle(font: .system(size: 13), horizontalPadding: 10))
                .fixedSize()
                .disabled(repairProgress == nil && !canRepair)
                .accessibilityLabel(repairProgress == nil ? "Repair both app sign-ins" : "Cancel app sign-in repair")
                .help("Sign in for each app in Chrome. Both saved sign-ins update automatically; the desktop reopens only when repairing its current account.")
            }
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
    let needsRepair: Bool
    let status: OpenChamberActionStatus?
    let saveHelp: String
    let switchHelp: String
    let save: () -> Void
    let switchAccount: () -> Void

    private var presentation: ProfileSignInPresentation {
        .init(hasSavedSignIn: hasSavedSignIn, needsRepair: needsRepair)
    }

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
            Label(presentation.statusText, systemImage: presentation.statusSymbol)
                .font(.system(size: 13))
                .foregroundStyle(needsRepair
                    ? CodexTheme.statusForegroundToken(for: .warning, preset: themeContext.preset).color
                    : CodexTheme.palette(for: themeContext.preset).supportText.color)
        }
    }

    @ViewBuilder private var actions: some View {
        if presentation.showsSave {
            Button(action: save) {
                Text("Save current sign-in").frame(minWidth: 128)
            }
            .buttonStyle(CodexQuietButtonStyle(font: .system(size: 13), horizontalPadding: 10))
            .disabled(isWorking)
            .accessibilityLabel("Save current \(title) sign-in")
            .help(saveHelp)
        } else {
            Button(action: switchAccount) {
                Label(switchTitle, systemImage: "arrow.triangle.2.circlepath")
                    .frame(minWidth: 128)
            }
            .buttonStyle(CodexSecondaryButtonStyle(font: .system(size: 13, weight: .semibold),
                                                  foregroundColor: CodexTheme.utilityActionTextToken(preset: themeContext.preset).color,
                                                  horizontalPadding: 10))
            .disabled(isWorking)
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
