# Profile Backup Implementation Plan

> Implement inline with executing-plans. The user explicitly authorized autonomous design, planning and execution.

**Goal:** One complete encrypted export and full restore for a new Mac.
**Architecture:** Streaming archive codec, validated manifest and filesystem service, portable cookie/preferences bridge, and one main-actor workflow with a compact native window.
**Tech Stack:** Swift 6, SwiftUI/AppKit, AppleArchive, Foundation, WebKit; macOS 14+.
**Spec:** `docs/superpowers/specs/2026-10-29-profile-backup-design.md`

## Global Constraints
- Preserve all profile fields and saved sign-in/rotation data; never read normal browser profiles or expose secrets.
- Use existing Everforest styles; one primary action per state, native panels, keyboard support.
- Same-volume staged restore, authenticated archive, owner-only temporary data, cancellation and recovery.
- No third-party runtime dependencies. Keep unrelated user files intact.

## Steps
- [x] Archive codec and validation: add BackupArchive, BackupManifest and tests. Prove encrypted roundtrip, wrong password, tamper/truncation, unsafe paths and size limits with real files.
- [x] Snapshot and restore service: add BackupService, portable cookie/preferences support and tests. Prove complete data preservation, rollback boundaries and startup receipt completion.
- [x] Runtime coordination: drain/pause profile and sync operations, reload controllers after restore, block concurrent edits, and test the gate with controlled async work.
- [x] Minimal native experience: add BackupTransferController/BackupTransferView, shared presenter, Settings/More/empty-state entry points, native sharing and isolated preview states.
- [x] Verification and review: run complete tests and strict build; exercise native previews and synthetic export→restore; perform a fresh code review and address material findings; update README and Learnings.

## Interfaces
- `BackupArchive.encode(directory:to:password:)` and `decode(from:to:password:)`: synchronous worker APIs, throwing, cancellation aware.
- `BackupManifest`: Codable/Sendable metadata, profile count, preferences data, portable cookie records keyed by profile UUID.
- `BackupService`: actor owning source/destination root and staging, exports archives, prepares/validates restores, commits staged data and retains recovery archives.
- `BackupTransferController`: main-actor observable UI state; owns task cancellation and invokes injected app quiescence/reload hooks.
- `BackupSessionBridge`: main-actor collection and replay of scoped cookies and allowlisted preferences; finishes durable receipts before normal app startup.

## Review Focus
- Concurrent refresh or account rotation cannot race a snapshot or replace newly restored credentials.
- Failed authentication or interrupted extraction never modifies active files or native sessions.
- Complete archive authentication and path validation happen before any replacement.
- Restore into an existing installation preserves an accessible recovery backup and does not reuse its WebKit store IDs.
- Real UI cancellation/closing cannot resume background writers while an archive task is still running.

## Execution ledger
- Planning: source, SDK, and Apple documentation researched. Work is authorized without further questions.
- Design tooling: 12ui requires interactive authentication; follow the established native design system and validate with local previews.
