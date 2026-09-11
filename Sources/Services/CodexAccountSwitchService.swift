import AppKit
import Foundation

struct CodexSavedAccount: Decodable, Sendable {
    let accountKey: String
    let chatgptAccountID: String
    let chatgptUserID: String
    let email: String
    let alias: String?
    let authMode: String?

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptUserID = "chatgpt_user_id"
        case email, alias
        case authMode = "auth_mode"
    }
}

struct CodexSavedAccountRegistry: Decodable, Sendable {
    let activeAccountKey: String?
    let accounts: [CodexSavedAccount]

    enum CodingKeys: String, CodingKey {
        case activeAccountKey = "active_account_key"
        case accounts
    }
}

enum CodexSwitchError: LocalizedError, Equatable {
    case missingRegistry
    case accountNotLinked
    case authFileMissing
    case identityMismatch
    case codexAuthMissing
    case chatGPTCouldNotClose
    case commandFailed(String)
    case reopenFailed(switched: Bool)

    var errorDescription: String? {
        switch self {
        case .missingRegistry: return "No saved Codex accounts were found. Open the account manager and sign in first."
        case .accountNotLinked: return "This profile is not linked to a saved Codex login."
        case .authFileMissing: return "The saved login file is missing. Sign in again in the account manager."
        case .identityMismatch: return "The saved login belongs to a different account. No account was switched."
        case .codexAuthMissing: return "codex-auth is not installed. Install it from Codex Auth Helper, then try again."
        case .chatGPTCouldNotClose: return "ChatGPT could not be closed, so the account was not switched."
        case .reopenFailed(let switched):
            return switched
                ? "Account switched, but ChatGPT could not open. Open ChatGPT manually."
                : "The account switch failed and ChatGPT could not reopen. Open ChatGPT manually."
        case .commandFailed(let message): return "Account switch failed: \(message)"
        }
    }
}

struct CodexAccountSwitchService: @unchecked Sendable {
    let homeDirectory: URL
    let fileManager: FileManager
    let commandPath: String?

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         fileManager: FileManager = .default,
         commandPath: String? = nil) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.commandPath = commandPath
    }

    var codexDirectory: URL { homeDirectory.appendingPathComponent(".codex") }
    var registryURL: URL { codexDirectory.appendingPathComponent("accounts/registry.json") }

    func migrate(_ profiles: [PlusProfile]) -> ([PlusProfile], changed: Bool) {
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONDecoder().decode(CodexSavedAccountRegistry.self, from: data) else { return (profiles, false) }
        var changed = false
        let migrated = profiles.map { profile -> PlusProfile in
            guard profile.provider == .codex, profile.codexAccountKey == nil else { return profile }
            let email = profile.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let match = registry.accounts.first(where: { $0.email.lowercased() == email }) else { return profile }
            var updated = profile; updated.codexAccountKey = match.accountKey; changed = true; return updated
        }
        return (migrated, changed)
    }

    func linkedAccount(for profile: PlusProfile) throws -> CodexSavedAccount {
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONDecoder().decode(CodexSavedAccountRegistry.self, from: data) else {
            throw CodexSwitchError.missingRegistry
        }
        if let key = profile.codexAccountKey, let account = registry.accounts.first(where: { $0.accountKey == key }) {
            return account
        }
        let normalized = profile.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let account = registry.accounts.first(where: { $0.email.lowercased() == normalized }) else {
            throw CodexSwitchError.accountNotLinked
        }
        return account
    }

    func switchAndOpen(profile: PlusProfile) async throws {
        let account = try linkedAccount(for: profile)
        let fileName = safeFileName(for: account.accountKey)
        let authURL = codexDirectory.appendingPathComponent("accounts/\(fileName).auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else { throw CodexSwitchError.authFileMissing }
        guard let auth = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: auth) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              tokenMatches(idToken: idToken, account: account) else {
            throw CodexSwitchError.identityMismatch
        }
        guard let executable = commandPath ?? resolveCommand() else { throw CodexSwitchError.codexAuthMissing }
        let appPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.path
            ?? "/Applications/ChatGPT.app"
        // codex-auth accepts email/alias/name selectors, while the stable key is
        // used above to choose the exact saved file and validate its identity.
        try await CodexSwitchWorkflow.perform(
            close: {
                let exitCode = try await CodexSwitchProcess.run(
                    executable: "/bin/zsh",
                    arguments: ["-f", "-c", Self.closeScript(appPath: appPath)]
                )
                guard exitCode == 0 else { throw CodexSwitchError.chatGPTCouldNotClose }
            },
            switchAccount: {
                try await CodexSwitchProcess.run(executable: executable, arguments: ["switch", account.email])
            },
            verifyAccount: {
                (try? self.activeAccountKey()) == account.accountKey && self.activeAuthMatches(account)
            },
            reopen: {
                try await CodexSwitchProcess.run(executable: "/usr/bin/open", arguments: ["-b", "com.openai.codex"])
            }
        )
    }

    // Only process termination uses a shell. Switching and opening are separate
    // awaited processes, so a shell error cannot skip the reopen operation.
    static func closeScript(appPath: String) -> String {
        let quoted = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        app=\(quoted); marker="$app/Contents/"
        pids() { /bin/ps -axo pid=,command= | /usr/bin/awk -v m="$marker" '{ p=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0); if (index($0,m)==1) print p; }'; }
        signalApp() {
          local app_pids="$(pids)"
          if [[ -n "$app_pids" ]]; then /bin/kill "-$1" ${(f)app_pids} 2>/dev/null || true; fi
        }
        signalApp TERM
        for i in {1..100}; do [[ -z "$(pids)" ]] && break; /bin/sleep 0.1; done
        signalApp KILL
        for i in {1..100}; do [[ -z "$(pids)" ]] && break; /bin/sleep 0.1; done
        [[ -z "$(pids)" ]]
        """
    }

    private func activeAuthMatches(_ account: CodexSavedAccount) -> Bool {
        guard let data = try? Data(contentsOf: codexDirectory.appendingPathComponent("auth.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return false }
        return tokenMatches(idToken: idToken, account: account)
    }

    private func activeAccountKey() throws -> String? {
        let data = try Data(contentsOf: registryURL)
        return try JSONDecoder().decode(CodexSavedAccountRegistry.self, from: data).activeAccountKey
    }

    private func resolveCommand() -> String? {
        let candidates = [
            homeDirectory.appendingPathComponent("Library/Application Support/CodexAuthHelper/codex-auth-tool/lib/node_modules/@loongphy/codex-auth/bin/codex-auth.js").path,
            "/opt/homebrew/bin/codex-auth", "/usr/local/bin/codex-auth"
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func safeFileName(for key: String) -> String {
        let valid = key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
        guard valid, key.isEmpty == false, key != ".", key != ".." else {
            return Data(key.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return key
    }

    private func tokenMatches(idToken: String, account: CodexSavedAccount) -> Bool {
        let pieces = idToken.split(separator: ".")
        guard pieces.count > 1 else { return false }
        var encoded = String(pieces[1]); encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return false }
        return (auth["chatgpt_account_id"] as? String) == account.chatgptAccountID && (auth["chatgpt_user_id"] as? String) == account.chatgptUserID
    }
}

/// Owns ordering and result handling independently of shell exit codes.
/// Once the app has closed, reopening is always attempted, including on errors.
enum CodexSwitchWorkflow {
    static func perform(
        close: () async throws -> Void,
        switchAccount: () async throws -> Int32,
        verifyAccount: () -> Bool,
        reopen: () async throws -> Int32
    ) async throws {
        try Task.checkCancellation()
        try await close()
        var switchFailure: Error?
        do {
            let exitCode = try await switchAccount()
            if exitCode != 0 {
                switchFailure = CodexSwitchError.commandFailed("codex-auth returned exit code \(exitCode)")
            }
        } catch {
            switchFailure = error
        }
        let switched = verifyAccount()
        let openExitCode = try? await reopen()
        guard openExitCode == 0 else { throw CodexSwitchError.reopenFailed(switched: switched) }
        guard switched else {
            throw switchFailure ?? CodexSwitchError.commandFailed("the selected login was not activated")
        }
    }
}

enum CodexSwitchProcess {
    static func run(executable: String, arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // GUI apps do not inherit an interactive shell's Homebrew PATH.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
                + (environment["PATH"] ?? "")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Install before starting: even an immediately exiting child must
            // complete the continuation exactly once.
            process.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus)
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
