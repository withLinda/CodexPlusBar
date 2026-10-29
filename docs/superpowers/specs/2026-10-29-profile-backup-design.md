# Profile backup and restore

## Intent
Move the complete CodexPlusBar setup from the old Mac into an empty installation on a new Mac using one private file. The user authorized implementation and design decisions without further approval gates. Keep the interface minimal, accessible, and consistent with the existing Everforest design system.

## Experience
- Settings has one Backup & Transfer section with Export Backup… and Restore Backup… actions. The manager's More menu exposes the same actions. The empty manager offers Restore Backup… beside Add profile; the existing text importer is named Import from Text… in More.
- Export asks for a password and confirmation, then uses the native save panel. A single dated `.codexplusbarbackup` file is produced. Success offers Show in Finder and the native Share action (including AirDrop).
- Restore uses a native open panel, asks for the password, authenticates and validates the entire file, then previews the date, app version, and profile count. One Restore action applies it. Existing destination data gets an encrypted recovery backup using the supplied password before replacement.
- Progress uses one sentence and a spinner, with cancellation before commit. Completion reports the actual restored count. Session verification distinguishes confirmed login failures from network failures.
- Passwords are never remembered, logged, or copied to the clipboard. Export requires at least eight characters. Error copy is short and does not expose credentials.

## Archive and data
Use Apple's supported AppleArchive framework (macOS 12+, within the project's macOS 14 floor), LZFSE compression, and its password-based scrypt / HKDF-SHA256 / AES-CTR-HMAC encrypted archive profile. This is an authenticated encrypted archive, not weak legacy ZIP encryption. Stream file contents with bounded memory. Archive schema 1 has a manifest and a Data directory.

Include profiles.json, dot-trick-sessions.json, DesktopSignIns, OpenChamberSignIns, and ChromeProfiles. Preserve profile UUIDs, provider identity, ordering, all detail fields, and rotation-recovery snapshots. Include only app-owned preferences and portable ChatGPT/Claude cookies obtained from the app's WebKit stores. Exclude disposable Chrome caches, runtime lock/port files, logs, generated bridge/plugin code and machine-local sync bookkeeping. Never read the user's normal browser profile or Keychain.

Raw Chrome data is retained, but its macOS-encrypted secrets cannot guarantee cross-Mac browser sign-in. Portable WebKit cookies restore native usage sessions independently of Chrome's machine key. Passwords/passkeys stored only by Chrome or Apple Passwords retain their normal platform migration requirements. The UI must not promise all sessions will stay signed in.

## Integrity and restoration
- Authenticate all encrypted bytes before presenting a ready-to-restore preview. Reject unknown schema versions, malformed manifests/catalogs, duplicate profile/store IDs, invalid paths, case/Unicode path collisions, symbolic/hard links, special files, unexpected top-level content, and resource limits.
- Limits: 100,000 entries, 64 GiB total uncompressed data, 16 MiB manifest, 64 MiB profile catalog. Fail cleanly with an actionable message; do not truncate data.
- Prepare in owner-only temporary storage adjacent to Application Support. Use 0700 directories and 0600 files. Remove staging on cancellation and failure.
- Pause profile mutations and automatic refresh/sync; drain active operations before snapshot or replacement. Close only app-owned browser sessions and reject any remaining writer to its Chrome directory. Email Tools edits participate in the same busy state.
- Restore cookies into new WebKit store UUIDs so existing native sessions are not overwritten before commit. Persist an idempotent restore receipt in the new data tree, containing the cookie and preferences work needed after a crash.
- Commit the prepared data tree using a same-volume atomic rename/swap. Failed precommit work leaves the destination intact. Startup finishes the receipt before starting refresh, pruning, or OpenChamber sync. Reload profile and Email Tools controllers after a successful restore.
- Recovery archives live outside the active data directory and are not recursively included in future backups. Never overwrite a successful export until a replacement is complete.

## Verification
Exercise real encrypted archive round trips and filesystem restoration with synthetic credentials. Cover wrong password, tampering, truncation, path traversal, symlinks, malformed data, unsupported version, cancellation, existing destination preservation, preferences, cookies, and recovery. Verify the actual SwiftUI export/restore states in the isolated preview host, including keyboard input, light/dark themes and narrow windows. Run the complete Swift Testing suite and a strict build.

## Research
- Apple documentation: https://developer.apple.com/documentation/applearchive/encrypting-and-decrypting-a-single-file
- Installed AppleArchive SDK interface confirms password-based authenticated encryption and streaming APIs, available since macOS 12.
- Existing app storage and import paths inspected: ProfileCatalogStore, ChromeProfileStore, WebSessionStore, DesktopSignIns, OpenChamberSignIns, PlusProfileController, and OpenChamberSyncScheduler.
- 12ui draft was attempted but its service requires an interactive sign-in. Use the established native controls and existing project tokens; validate rendered native screens locally.
