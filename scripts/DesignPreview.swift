// Native visual QA host. Compiled by render_design.sh, never included in the app.
import AppKit
import SwiftUI

private struct PreviewSignInChecker: OpenChamberSignInChecking {
    var slow = false
    func check(profiles: [PlusProfile], didCheck: @escaping @Sendable (OpenChamberSignInCheckUpdate) async -> Void) async throws {
        for (index, profile) in profiles.enumerated() {
            if slow { try await Task.sleep(for: .seconds(1)) }
            try Task.checkCancellation()
            await didCheck(.init(profileID: profile.id, record: .init(identityKey: profile.openCodeOpenAIAccount?.storageKey,
                outcome: index == 0 || index == 2 ? .needsSignIn : .verified, checkedAt: .now)))
        }
    }
}

private struct PreviewRepairService: AppSignInRepairing {
    var slow = false
    var partial = false
    func repair(profile: PlusProfile, openURL: @escaping @Sendable (URL) async throws -> Void,
                progress: @escaping @Sendable (AppSignInRepairProgress) async -> Void,
                completed: @escaping @Sendable (AppSignInRepairCompletion) async throws -> Void,
                isCurrent: @escaping @Sendable () async -> Bool) async throws {
        let identity = profile.codexSignIn ?? .init(accountID: "preview", userID: "preview", email: profile.label)
        for destination in AppSignInDestination.allCases {
            await progress(.init(profileID: profile.id, destination: destination,
                message: "\(destination == .desktop ? "1" : "2") of 2 · Sign in to \(destination.title) in Chrome."))
            if slow { try await Task.sleep(for: .seconds(60)) }
            try Task.checkCancellation()
            if partial && destination == .openChamber { throw AppSignInRepairError.denied }
            try await completed(.init(destination: destination, identity: identity))
        }
    }
}

// The real menu-bar popover becomes key. Let its borderless QA host do the same
// so native keyboard checks exercise the production window-scoped shortcuts.
private final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@main
enum DesignPreview {
    @MainActor private static let commands = PreviewCommands()

    @MainActor static func main() throws {
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        defaults.set(arguments.contains("--light") ? "light" : "dark", forKey: CodexThemeSettings.Keys.appearanceMode)
        defaults.set(arguments.contains("--soft") ? "soft" : arguments.contains("--medium") ? "medium" : "hard", forKey: CodexThemeSettings.Keys.contrast)
        defaults.set(arguments.contains("--original") ? "original" : arguments.contains("--dim") ? "dim" : "deep", forKey: CodexThemeSettings.Keys.canvas)
        defaults.set(arguments.contains("--large-text") ? 1.35 : 1, forKey: MenuBarPanelTextScalePreference.textScaleKey)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appearanceItem = appMenu.addItem(withTitle: "Toggle appearance", action: #selector(PreviewCommands.toggleAppearance), keyEquivalent: "t")
        appearanceItem.target = commands
        let restoreFixtureItem = appMenu.addItem(withTitle: "Restore same profile fixture", action: #selector(PreviewCommands.restoreFixture), keyEquivalent: "r")
        restoreFixtureItem.target = commands
        let preserveClipboard = appMenu.addItem(withTitle: "Preserve clipboard for checks", action: #selector(PreviewCommands.preserveClipboard), keyEquivalent: "b")
        preserveClipboard.keyEquivalentModifierMask = [.command, .shift]
        preserveClipboard.target = commands
        let restoreClipboard = appMenu.addItem(withTitle: "Restore clipboard after checks", action: #selector(PreviewCommands.restoreClipboard), keyEquivalent: "k")
        restoreClipboard.keyEquivalentModifierMask = [.command, .shift]
        restoreClipboard.target = commands
        appMenu.addItem(withTitle: "Quit preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Select All", "selectAll:", "a"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        app.mainMenu = mainMenu
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexPlusBar-Design-\(UUID())")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let controller = PlusProfileController(
            catalogStore: ProfileCatalogStore(fileURL: temporaryDirectory.appendingPathComponent("profiles.json")),
            dataService: PreviewDataService(),
            accountSwitchService: PreviewDesktopService(failure: arguments.contains("--sign-in-error") ? .unauthorized : arguments.contains("--sign-in-network-error") ? .unavailable : nil),
            openCodeAuthService: PreviewOpenCodeService(failure: arguments.contains("--sign-in-error") ? .reauthenticationRequired : arguments.contains("--sign-in-network-error") ? .unavailable : nil),
            syncService: PreviewSyncService(),
            signInChecker: PreviewSignInChecker(slow: arguments.contains("--check-progress")),
            repairService: PreviewRepairService(slow: arguments.contains("--repair-progress"), partial: arguments.contains("--repair-partial")),
            autoStart: false
        )
        let now = Date(timeIntervalSince1970: 1_789_473_600)
        controller.profiles = arguments.contains("--empty") ? [] : fixtures(
            now: now, missingExpiry: arguments.contains("--missing-expiry")
        )
        if arguments.contains("--empty-notes"), let first = controller.profiles.first {
            var profile = first.profile
            profile.notes = nil
            controller.profiles[0] = first.updating(profile: profile)
        }
        controller.selectedProfileID = controller.profiles.first?.id
        if arguments.contains(where: { $0.hasPrefix("--repair-") }), let first = controller.profiles.first {
            Task { await controller.repairBothSignIns(profileID: first.id) }
        }
        if arguments.contains("--check-sign-ins") || arguments.contains("--check-progress") {
            Task { await controller.checkAllOpenChamberSignIns() }
        }
        commands.restoreAction = {
            guard let original = controller.selectedProfile?.profile else { return }
            do {
                var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
                json["webDataStoreID"] = UUID().uuidString
                json["notes"] = "Restored notes must survive"
                let restored = try JSONDecoder().decode(PlusProfile.self, from: JSONSerialization.data(withJSONObject: json))
                try ProfileCatalogStore(fileURL: temporaryDirectory.appendingPathComponent("profiles.json")).saveProfiles([restored])
                controller.resumeAfterBackup(reload: true, startTasks: false)
            } catch { print("Fixture restore failed: \(error)") }
        }
        if arguments.contains("--unsaved"), !controller.profiles.isEmpty {
            var profile = controller.profiles[0].profile
            profile.codexSignIn = nil
            profile.openCodeOpenAIAccount = nil
            controller.profiles[0] = controller.profiles[0].updating(profile: profile)
        }
        if arguments.contains("--sign-in-error") || arguments.contains("--sign-in-network-error"), let first = controller.profiles.first {
            Task { @MainActor in
                await controller.switchAndOpen(profileID: first.id)
                await controller.switchOpenChamberAuth(profileID: first.id)
            }
        }
        controller.dashboardStatus = controller.profiles.isEmpty ? .empty : .ready
        if arguments.contains("--error"), let last = controller.profiles.last {
            controller.selectedProfileID = last.id
        }
        if arguments.contains("--loading") { controller.isRefreshing = true }
        if arguments.contains("--switching"), let first = controller.profiles.first {
            controller.switchingProfileIDs.insert(first.id)
            controller.openCodeSwitchingProfileIDs.insert(first.id)
            controller.desktopSignInStatus = .init(profileID: first.id, message: "Switching and reopening ChatGPT / Codex…", tone: .info)
        }
        let clock = AppMinuteClock(now: now)
        let isPanel = arguments.contains("--panel")
        let isEmailTools = arguments.contains("--email-tools")
        let isBackup = arguments.contains(where: { $0.hasPrefix("--backup-") })
        let isSettings = arguments.contains("--settings")
        let size = isPanel
            ? CGSize(width: MenuBarPanelMetrics.width, height: MenuBarPanelMetrics.height)
            : isBackup ? CGSize(width: 480, height: 360)
            : isSettings ? CGSize(width: 460, height: 440)
            : isEmailTools ? (arguments.contains("--empty") ? EmailToolsLayout.emptySize : arguments.contains("--compact") ? EmailToolsLayout.minimumSize : EmailToolsLayout.defaultSize)
            : arguments.contains("--empty") ? ProfileManagerLayout.emptySize
            : arguments.contains("--compact") ? ProfileManagerLayout.minimumSize : ProfileManagerLayout.defaultSize
        let window = PreviewWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: isPanel ? [.borderless] : isBackup || isSettings ? [.titled, .closable] : [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        let root: AnyView
        if isBackup {
            try ProfileCatalogStore(fileURL: temporaryDirectory.appendingPathComponent("profiles.json")).saveProfiles(controller.profiles.map(\.profile))
            let transfer = BackupTransferController(profiles: controller,
                email: DotTrickController(store: DotTrickSessionStore(fileURL: temporaryDirectory.appendingPathComponent("dot-trick-sessions.json"))),
                root: temporaryDirectory)
            transfer.window = window
            if arguments.contains("--backup-restore") {
                transfer.mode = .restore
                transfer.sourceURL = temporaryDirectory.appendingPathComponent("CodexPlusBar-2026-10-29.codexplusbarbackup")
                if let index = arguments.firstIndex(of: "--backup-file"), arguments.indices.contains(index + 1) {
                    transfer.sourceURL = URL(fileURLWithPath: arguments[index + 1])
                }
            }
            if arguments.contains("--backup-ready") {
                transfer.mode = .restore
                transfer.prepared = PreparedBackup(id: UUID(), directory: temporaryDirectory,
                    manifest: BackupManifest(profileCount: 35, preferences: .init(), cookies: [:]))
                transfer.phase = .preview
            }
            if arguments.contains("--backup-success") {
                transfer.phase = .exported(temporaryDirectory.appendingPathComponent("CodexPlusBar-2026-10-29.codexplusbarbackup"))
            }
            if arguments.contains("--backup-error") { transfer.errorMessage = BackupError.unlockFailed.localizedDescription }
            if arguments.contains("--backup-working") { transfer.phase = .working("Compressing and encrypting…"); transfer.isBusy = true }
            root = AnyView(BackupTransferView(controller: transfer))
        } else if isPanel {
            root = AnyView(MenuBarRootView(controller: controller, currentTime: clock, openManagerWindow: { _ in }, openEmailToolsWindow: {}))
        } else if isEmailTools {
            let emailController = DotTrickController(store: DotTrickSessionStore(fileURL: temporaryDirectory.appendingPathComponent("email-sessions.json")))
            if !arguments.contains("--empty") {
                emailController.addSession(localPart: "personalnotes")
                emailController.addSession(localPart: "designreview")
                if let session = emailController.selectedSession {
                    for variation in session.variations.prefix(2) {
                        emailController.toggleUsed(variation: variation, inSession: session.id)
                    }
                }
            }
            root = AnyView(EmailToolsWindowView(controller: emailController))
        } else if isSettings {
            root = AnyView(CodexSettingsView())
        } else {
            root = AnyView(ProfileManagerWindowView(controller: controller, currentTime: clock, initiallyShowsDetails: arguments.contains("--details"), initialPage: arguments.contains("--phone-summary") ? .phoneSummary : .profile))
        }
        window.contentView = NSHostingView(rootView: root.background(PreviewAccessibilityProbe().frame(width: 0, height: 0)))
        if arguments.contains("--accessible") {
            window.appearance = NSAppearance(named: arguments.contains("--light") ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
        }
        window.title = "CodexPlusBar Design Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        print("Native preview window: \(window.windowNumber)")
        if let outputIndex = arguments.firstIndex(of: "--output"), arguments.indices.contains(outputIndex + 1) {
            let output = arguments[outputIndex + 1]
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(1))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output]
                    try capture.run()
                    capture.waitUntilExit()
                    guard capture.terminationStatus == 0 else { exit(capture.terminationStatus) }
                    if arguments.contains("--cycle-theme") || arguments.contains("--cycle-canvas") {
                        let cyclingCanvas = arguments.contains("--cycle-canvas")
                        let key = cyclingCanvas ? CodexThemeSettings.Keys.canvas : CodexThemeSettings.Keys.appearanceMode
                        let transitions = cyclingCanvas
                            ? [("original", "-original"), ("dim", "-dim"), ("deep", "-deep-again")]
                            : [("light", "-light"), ("dark", "-dark-again")]
                        for (mode, suffix) in transitions {
                            defaults.set(mode, forKey: key)
                            try await Task.sleep(for: .milliseconds(500))
                            let target = URL(fileURLWithPath: output).deletingPathExtension().path + suffix + ".png"
                            let nextCapture = Process()
                            nextCapture.executableURL = capture.executableURL
                            nextCapture.arguments = ["-x", "-o", "-l", String(window.windowNumber), target]
                            try nextCapture.run()
                            nextCapture.waitUntilExit()
                            guard nextCapture.terminationStatus == 0 else { exit(nextCapture.terminationStatus) }
                        }
                    }
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                    app.terminate(nil)
                } catch {
                    FileHandle.standardError.write(Data("Preview capture failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
        app.run()
    }

    private static func fixtures(now: Date, missingExpiry: Bool) -> [PlusProfileSnapshot] {
        let labels = ["studio@example.com", "research@example.com", "alex.personal@example.com", "a.long.profile.name.for.layout.review@example.com", "backup@example.com", "team@example.com"]
        let remaining = [82, 24, 100, 0, 68, 0]
        return labels.enumerated().map { index, label in
            let profile = PlusProfile(
                id: UUID(), provider: .codex,
                label: label,
                codexSignIn: index == 0 || index == 2 ? CodexSignInIdentity(accountID: "preview-\(index)", userID: "preview", email: label) : nil,
                openCodeOpenAIAccount: index == 0 || index == 3 ? OpenCodeOpenAIIdentity(accountID: "preview-\(index)", userID: "preview", email: label) : nil,
                emailLink: "https://example.com/inbox", detectedNote: "Plus",
                password: "preview-only", twoFactorCode: "JBSWY3DPEHPK3PXP",
                phoneNumber: index < 3 ? "+1 202 555 0123" : index == 3 ? "+1 202 555 0198" : nil,
                notes: "A quiet place for account notes.",
                expiresAt: missingExpiry ? nil : now.addingTimeInterval(Double(index + 3) * 86_400),
                tags: [index == 3 || index == 5 ? .needAction : index == 1 ? .pending : .active],
                webDataStoreID: UUID(), sortOrder: index, createdAt: now,
                lastRefreshAt: now.addingTimeInterval(-120), lastKnownState: index == 5 ? .needsLogin : .active
            )
            return PlusProfileSnapshot(
                profile: profile, state: index == 5 ? .needsLogin : .ready,
                usage: index == 5 ? nil : PlusProfileUsage(
                    accountID: "preview-\(index)", planType: "plus",
                    primaryWindow: WorkspaceLimitWindow(usedPercent: 100 - remaining[index], resetAt: now.addingTimeInterval(7_200 + Double(index) * 600)),
                    secondaryWindow: index == 4 ? nil : WorkspaceLimitWindow(usedPercent: 100 - (index == 2 ? 100 : 64), resetAt: now.addingTimeInterval(280_800)),
                    fetchedAt: now
                ),
                statusMessage: index == 5 ? "Sign in again to refresh usage." : nil,
                isRefreshing: false
            )
        }
    }
}

private struct PreviewAccessibilityProbe: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let state = "reduceTransparency=\(reduceTransparency) reduceMotion=\(reduceMotion) increasedContrast=\(contrast == .increased)"
        Color.clear.task(id: state) { print("SwiftUI accessibility: \(state)") }
    }
}

@MainActor
private final class PreviewCommands: NSObject {
    private var clipboardSnapshot: [NSPasteboardItem]?
    var restoreAction: () -> Void = {}
    @objc func restoreFixture() { restoreAction() }

    @objc func preserveClipboard() {
        guard clipboardSnapshot == nil else { return }
        clipboardSnapshot = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    @objc func restoreClipboard() {
        guard let clipboardSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(clipboardSnapshot)
        self.clipboardSnapshot = nil
    }

    @objc func toggleAppearance() {
        let defaults = UserDefaults.standard
        let isLight = defaults.string(forKey: CodexThemeSettings.Keys.appearanceMode) == "light"
        defaults.set(isLight ? "dark" : "light", forKey: CodexThemeSettings.Keys.appearanceMode)
    }
}

private struct PreviewOpenCodeService: OpenCodeOpenAIAuthServing {
    let failure: OpenCodeOpenAIVerificationError?
    func saveCurrent(for profile: PlusProfile) async throws -> OpenCodeOpenAIIdentity {
        OpenCodeOpenAIIdentity(accountID: "preview", userID: "preview", email: profile.label)
    }
    func switchTo(profile: PlusProfile) async throws {
        if let failure { throw OpenCodeOpenAISwitchError(cause: failure, recovery: .restored) }
    }
}

private struct PreviewSyncService: OpenChamberSyncServing {
    func reconcile(catalog: OpenChamberSyncCatalog, isCurrent: @escaping @Sendable (UInt64) async -> Bool) async throws -> OpenChamberSyncResult {
        let profiles = catalog.profiles.filter { $0.provider == .codex }
        let missing = Set(profiles.filter { $0.openCodeOpenAIAccount == nil }.map(\.id))
        return .init(matchedCount: profiles.count - missing.count, totalCount: profiles.count,
                     needsSignInProfileIDs: missing, pendingCredentialCount: 0, deferredActiveRemoval: false)
    }
}

private struct PreviewDesktopService: CodexAccountSwitchServing {
    let failure: CodexSignInError?
    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity {
        CodexSignInIdentity(accountID: "preview", userID: "preview", email: profile.label)
    }
    func switchAndOpen(profile: PlusProfile) async throws {
        if let failure { throw CodexSignInSwitchError(cause: failure, recovery: .restored, reopenFailed: false) }
    }
}

@MainActor
private final class PreviewDataService: PlusProfileDataServing {
    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult { throw CancellationError() }
    func openChromeSignIn(for profile: PlusProfile) async throws {}
    func openChromeAccountPage(for profile: PlusProfile) async throws {}
    func openChromePasskeySetup(for profile: PlusProfile) async throws {}
    func syncChromeSession(for profile: PlusProfile) async throws {}
    func waitForChromeSignInToFinish(for profile: PlusProfile) async -> Bool { false }
    func closeChromeSignIn(for profile: PlusProfile) async {}
    func clearSession(for profile: PlusProfile) async throws {}
    func removeProfileData(for profile: PlusProfile) async throws {}
}
