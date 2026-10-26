# Automatic OpenChamber account-list sync

## Intent

CodexPlusBar is the source of truth for which OpenAI accounts appear in local OpenChamber. The user frequently removes expired accounts from CodexPlusBar and wants those accounts removed from OpenChamber automatically. The target is the current saved profile list, not a hardcoded list of ten accounts.

The user confirmed exact mirroring after reviewing the native API approach. This specification defines the remaining implementation details for review.

## Verified starting point

- Installed OpenChamber 2.5.2 runs OpenCode 2.1.4. Its live API supports credential listing, creation, label updates, activation, and deletion.
- Research found ten CodexPlusBar Codex profiles and 27 OpenChamber OpenAI OAuth connections. Nine profiles have saved OpenChamber links and snapshots; the tenth has no saved OpenChamber or native Codex sign-in. Browser login alone is not an OAuth credential.
- `OpenCodeV2Client` currently uses a location-scoped plugin for per-account save and switch. `PlusProfileController` owns profile persistence and background work.
- Old saved sign-in files outnumber current profiles. Those files are recovery material, not the desired account list.

## User-visible behavior

Provide one persistent **Automatically sync OpenChamber** setting, enabled for this requested integration. Explain it with: “Keep OpenChamber's OpenAI logins matched to your saved Codex profiles, including removals.” Disabling it stops future reconciliation.

While enabled:

- Launch and successfully saved profile changes schedule sync. Coalesce repeated edits for one second. A lightweight 60-second retry catches OpenChamber reopening and changes made in OpenChamber.
- Retain or link matching logins, add missing logins when a supported saved OAuth sign-in exists, update their display labels, and remove surplus OpenAI OAuth logins.
- Removing a profile removes its corresponding OpenChamber login. Adding an OpenChamber-only login does not create a CodexPlusBar profile; it is removed on a later reconciliation unless linked to a current profile.
- Membership follows persisted Codex profiles, regardless of temporary search, sorting, tags, usage errors, or expiry display. Expiry itself does not delete a profile.
- Show one compact sync status and a **Sync now** action in existing profile-manager controls. Missing credentials produce a per-profile “OpenChamber sign-in needed” state. Report partial sync honestly, for example “9 of 10 profiles linked; 1 needs sign-in.”

This manages saved OpenAI OAuth logins in the verified local OpenChamber backend. Other providers, API keys, and environment connections are outside this login-list mirror. The backend's saved connections are shared with any clients using that same backend.

## Identity and credentials

Use OpenAI account ID plus user ID as the logical identity; retain native credential IDs as bindings. Profile UUIDs identify local rows. Email is only a one-time matching hint when exactly one current profile and one decoded OAuth identity match; persist the resolved identity before pruning. Never use display-label changes as proof of a different account.

For an account with duplicate native credentials, keep the active matching credential when possible, otherwise the already-bound credential, otherwise a deterministic credential-ID choice. Duplicate local rows for one logical account map to one native login.

Use the native API:

- `GET /api/integration/openai` for connection inventory.
- `GET /api/credential` for credential values and active flags; filter immediately to OpenAI, keep secrets out of logs and profile JSON.
- `POST /api/credential` with the original supported OAuth method and metadata, and `activate: false`, to add missing credentials. The first credential can still become active when none exists.
- `PATCH /api/credential/{id}` for labels.
- `POST /api/credential/{id}/activate` and `DELETE /api/credential/{id}` for account lifecycle.

Prefer current native credentials over older snapshots. Preserve OpenCode's token-refresh ownership and complete OAuth method/metadata. Background list sync does not independently refresh retained tokens. Only recover saved snapshots that belong to a current profile, through existing identity and live-verification rules. A profile without an importable OAuth sign-in waits for a one-time sign-in; never create an empty credential.

Retain the existing bridge for legacy manual switching compatibility. Automatic mirroring requires the verified native list/create API; unsupported runtimes report that requirement instead of editing `auth.json` or SQLite. Newly supported OAuth methods must have explicit identity parsing coverage before reconciliation can classify them.

## Reconciliation and active-account rules

A dedicated actor serializes reconciliation with existing save/switch operations. Separate a pure reconciliation planner from network execution so membership, duplicate selection, and removals can be tested directly.

1. Obtain a successfully loaded, successfully persisted catalog generation and a complete native inventory.
2. Resolve identities and persist new bindings; add missing eligible credentials before removal.
3. Recheck catalog generation and native inventory before executing the removal set. Replan on concurrent changes, unknown identities, malformed responses, or ambiguous matches rather than treating them as absent accounts.
4. Keep the current active account when it is still in the desired set. List sync otherwise does not change the account selected for coding.
5. If the active account was removed from CodexPlusBar, defer its removal and replacement while the backend reports running sessions. Once idle, activate the first available desired credential in saved profile order and remove the old one. If no desired credential exists, remove the old login and report that OpenChamber needs a sign-in. Failure to establish idle state defers this operation. This is a best-effort idle check, not an atomic lock on session starts.
6. Remove other surplus and duplicate OAuth credentials, then reread the inventory to verify the result.

Retries recompute from actual server state. A timeout after a successful create or delete must not create duplicates or resurrect removed accounts. Cancellation and preference changes stop subsequent operations; an in-flight request may have already completed.

Only committed catalog changes authorize pruning. The current controller substitutes an empty array after a catalog-read error and ignores a persistence failure in `removeProfile`; sync must distinguish those failures from an intentional empty catalog. A missing/unreadable catalog never authorizes deleting all logins. A deliberately saved empty Codex list does, using the same idle rule for its active account.

## Integration boundaries

- Extend `OpenCodeLocalRuntime` and the native API client for capability checks and typed inventory/lifecycle operations.
- Add a focused planner and serialized sync coordinator beside existing OpenCode services. Coordinate manual authentication operations through the same operation ownership.
- Hook `PlusProfileController` into successful catalog persistence and startup, keeping network work off the main actor. Membership changes during awaited work invalidate that pass.
- Keep binding updates generation-checked and prevent them from causing an endless sync loop.
- Add the preference and compact status to existing settings/profile-manager patterns.

## Verification

Meaningful tests must cover addition, deletion, relabeling, duplicate identities, preserved active selection, active-account removal after idle, intentional empty catalogs, missing/read-failed catalogs, failed saves, concurrent edits, partial network failure, uncertain create/delete outcomes, stale snapshots, unsupported OAuth methods, and unrelated providers/API keys.

Use an isolated OpenCode server and synthetic credentials to verify native API semantics, including `activate: false` and deletion. Run the repository's `make test` and `make build`, confirming the actual Swift Testing count. Verify live UI status and resulting account inventory when the completed integration is enabled; report profiles that still require OAuth sign-in rather than claiming a complete ten-account mirror prematurely.
