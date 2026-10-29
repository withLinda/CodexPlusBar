import SwiftUI

struct BackupTransferView: View {
    @Bindable var controller: BackupTransferController
    @Environment(\.codexThemeRefreshContext) private var themeContext
    @FocusState private var focusedField: Field?
    private enum Field { case password, confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(ProfileManagerTypography.title)
                    .foregroundStyle(CodexTheme.headingText)
                Text(subtitle)
                    .font(ProfileManagerTypography.body)
                    .foregroundStyle(CodexTheme.supportText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content

            if let error = controller.errorMessage {
                Text(error)
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(CodexTheme.supportText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backup.error")
            }

            actions
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .background(CodexBackdrop())
        .codexThemeRefreshScope()
        .onAppear { focusedField = .password }
        .onChange(of: controller.mode) { _, _ in focusedField = .password }
        .onChange(of: controller.isBusy) { _, busy in if !busy { focusedField = .password } }
    }

    private var title: String {
        switch controller.phase {
        case .exported: "Backup ready"
        case .restored: "Welcome to your new Mac"
        case .recoveryNeeded: "Finish restoring"
        default: controller.mode == .export ? "Export backup" : "Restore backup"
        }
    }

    private var subtitle: String {
        switch controller.phase {
        case .exported: "Send this file to your new Mac, then choose Restore Backup."
        case let .restored(count): "\(count) profile\(count == 1 ? "" : "s") restored, with saved details and sign-ins."
        case .recoveryNeeded: "Your backup has been installed."
        default: controller.mode == .export
            ? "Your profiles, saved sign-ins and settings in one private file."
            : "Bring your profiles and settings to this Mac."
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .password:
            VStack(alignment: .leading, spacing: 14) {
                if controller.mode == .restore, let file = controller.sourceURL {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.zipper").foregroundStyle(CodexTheme.supportText)
                        Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Change…", action: controller.chooseBackup).buttonStyle(.link)
                    }
                    .font(ProfileManagerTypography.small)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password").font(ProfileManagerTypography.smallStrong)
                    SecureField("", text: $controller.password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("Backup password")
                        .accessibilityIdentifier("backup.password")
                        .onSubmit {
                            if controller.mode == .export { focusedField = .confirmation }
                            else { controller.submitPassword() }
                        }
                }
                if controller.mode == .export {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Confirm password").font(ProfileManagerTypography.smallStrong)
                        SecureField("", text: $controller.confirmation)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .confirmation)
                            .accessibilityLabel("Confirm backup password")
                            .accessibilityIdentifier("backup.confirmation")
                            .onSubmit(controller.submitPassword)
                    }
                    Text("At least 8 characters. Keep this password to restore your backup.")
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.supportText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(CodexTheme.primaryText)
        case .preview:
            if let manifest = controller.prepared?.manifest {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(manifest.profileCount) profile\(manifest.profileCount == 1 ? "" : "s")")
                        .font(ProfileManagerTypography.bodyStrong)
                    Text("\(manifest.createdAt.formatted(date: .abbreviated, time: .shortened)) · CodexPlusBar \(manifest.appVersion)")
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.supportText)
                    Text(controller.replacesExistingData
                         ? "Replaces this Mac’s data. A recovery backup is saved first, with the same password."
                         : "Ready to restore. Some accounts may need a fresh sign-in.")
                        .font(ProfileManagerTypography.small)
                        .foregroundStyle(CodexTheme.supportText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case let .working(message):
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(message).font(ProfileManagerTypography.body)
            }
            .frame(minHeight: 64, alignment: .leading)
            .accessibilityElement(children: .combine)
        case let .exported(url):
            Label(url.lastPathComponent, systemImage: "doc.zipper")
                .font(ProfileManagerTypography.small)
                .foregroundStyle(CodexTheme.supportText)
                .lineLimit(2)
        case .restored:
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.sessionSummary)
                    .font(ProfileManagerTypography.small)
                    .foregroundStyle(CodexTheme.supportText)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = controller.recoveryURL {
                    Button("Show recovery backup") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) }
                        .buttonStyle(.link).font(ProfileManagerTypography.small)
                }
            }
        case .recoveryNeeded: EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case let .exported(url):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(CodexSecondaryButtonStyle())
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(CodexSecondaryButtonStyle())
                Spacer(minLength: 0)
                Button("Done", action: controller.cancel).buttonStyle(CodexPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            case .restored:
                Spacer()
                Button("Open Profiles") { controller.cancel(); controller.showProfiles() }
                    .buttonStyle(CodexPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            case .recoveryNeeded:
                Spacer()
                Button("Quit CodexPlusBar") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(CodexPrimaryButtonStyle())
            default:
                Spacer(minLength: 0)
                Button("Cancel", action: controller.cancel)
                    .buttonStyle(CodexSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(controller.isCommitting)
                if case .password = controller.phase {
                    Button(controller.mode == .export ? "Export Backup…" : "Unlock Backup", action: controller.submitPassword)
                        .buttonStyle(CodexPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!controller.canSubmitPassword)
                        .accessibilityIdentifier("backup.submit")
                } else if case .preview = controller.phase {
                    Button("Restore", action: controller.restoreBackup)
                        .buttonStyle(CodexPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("backup.restore")
                }
            }
        }
    }
}
