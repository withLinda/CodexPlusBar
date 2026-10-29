# Profile backup verification — 2026-10-29

## Scope
One encrypted `.codexplusbarbackup` file transfers saved profiles, all detail fields, desktop/OpenChamber sign-in vaults and rotation recovery, Email Tools, app preferences, dedicated Chrome data, and portable native cookies. The implementation targets macOS 14+ and uses AppleArchive with LZFSE and authenticated password encryption.

## Integrity checks
- Real encrypted byte-for-byte roundtrip, including a file larger than the streaming buffer.
- Wrong password, tampering, truncation, appended garbage and concatenated encrypted containers.
- Traversal, links, duplicate paths, Unicode aliases (`SS`/`ß`, `Σ`/`ς`), and aliased parent directories.
- Declared extraction size limits, bounded eagerly parsed JSON, and symmetric export/import manifest limits.
- Cancelled export preserves an existing backup; cancelled commit preserves the active catalog and permits a validated retry.
- Same-volume restore uses a separate install tree and an atomic swap. A durable receipt replays cookies and preferences before normal startup work.
- Transfer coordination drains an active sign-in save and refuses new mutations. Native file panels retain workflow ownership until they close.

## Review findings addressed
One independent full-feature review identified stale runtimes, stale edit drafts, Unicode file collisions, unbounded JSON reads, and accepted trailing bytes. Regression checks reproduced each issue before correction. Restored stores remain alive until normal runtime ownership; runtime caches compare both profile and store IDs. The mounted detail form refreshes when restore changes its store ID.

The additional panel/recovery and oversized-manifest regressions also failed before their fixes. No review finding remains open.

## Native UI evidence
- Isolated `CodexPlusBarDesignPreview` uses synthetic profiles and stub network services.
- Dark export and light restore-preview screens; error, progress, completion, Settings and empty-manager states inspected.
- Real secure-field typing, Return focus, theme-switch preservation, password validation and native save-panel presentation checked with `scripts/inspect_backup.applescript`.
- Real export followed by restore into an empty preview installation exercised with `scripts/backup_ui_roundtrip.applescript`; six synthetic profiles restored. Stubbed networking was reported as unchecked sessions, not rejected sign-ins.
- `scripts/inspect_backup_draft.applescript` reproduces a same-ID restore in a mounted manager. The old view fails and the corrected view displays the restored notes. Invoke its explicit menu item; Cmd-R belongs to the normal Refresh action too.

## Final results
- `make test AGENT_NAME=backup-transfer`: **447 tests in 49 suites passed**, with `TEST SUCCEEDED` and normal exit. Log: `build/backup-transfer-final-tests.log`.
- `make build AGENT_NAME=backup-transfer`: **BUILD SUCCEEDED**, warnings treated as errors and strict Swift concurrency enabled. Log: `build/backup-transfer-final-build.log`.
- Final native keyboard/save-panel check passed, followed by a fresh UI export and empty-install restore of `build/ui-roundtrip-final.codexplusbarbackup`.
- `git diff --check` and `plutil -lint Sources/Info.plist` passed.

## Boundaries
The installed production app and live account data were not replaced. Chrome's machine-bound encrypted secrets may require a fresh sign-in on the new Mac. Transfer of a still-valid native cookie does not guarantee the provider will accept it from another machine. 12ui required interactive authentication, so visual decisions used the project's existing native style and locally rendered evidence.

## Release 1.3.0 (build 14)
- `xcodegen generate` regenerated the project from the updated version source.
- `make test AGENT_NAME=backup-release`: **447 tests in 49 suites passed**, `TEST SUCCEEDED`, normal exit. Log: `build/backup-release-tests.log`.
- `make archive AGENT_NAME=backup-release ARCHIVE_PATH="$PWD/build/release-1.3.0/CodexPlusBar.xcarchive"`: **ARCHIVE SUCCEEDED**. The archive and mounted DMG app report version **1.3.0**, build **14**, minimum macOS **14.0**, and architectures **x86_64 arm64**.
- Archived app signed with Developer ID, hardened runtime and timestamp; DMG created with `scripts/create_dmg.sh`, then Developer ID-signed.
- Apple notarization **Accepted**, submission `f68a7b23-caf0-4659-a16b-a719560fdfdf`; DMG ticket stapled and validated.
- Strict signature verification and Gatekeeper checks passed for the app and DMG (`Notarized Developer ID`); `hdiutil verify` passed.
- Read-only DMG inspection confirmed the app's version/architectures/signature and `/Applications` shortcut, then detached the volume.
- SHA256 generated after stapling; `shasum -a 256 -c CodexPlusBar.dmg.sha256` returned **OK**.
- Intel hardware execution was not run; the universal binary was inspected. Release validation did not replace the installed production app.
