# Automatic OpenChamber account-list sync

## Intent

CodexPlusBar is the source of truth for which OpenAI accounts appear in local OpenChamber. The user frequently removes expired accounts from CodexPlusBar and wants those accounts removed from OpenChamber automatically. The target is the current saved profile list, not a hardcoded list of ten accounts.

The user confirmed exact mirroring after reviewing the native API approach, clarified that device-code login followed by Save current sign-in must remain the normal workflow, and requested a visible Remove button beside Refresh. This specification defines those behaviors for review.

## Verified starting point

- Installed OpenChamber 2.5.2 runs OpenCode 2.1.4. Its live API supports credential listing, creation, label updates, activation, and deletion.
- Research found ten CodexPlusBar Codex profiles and 27 OpenChamber OpenAI OAuth connections. Nine profiles have saved OpenChamber links and snapshots; the tenth has no saved OpenChamber or native Codex sign-in. Browser login alone is not an OAuth credential.
- `OpenCodeV2Client` currently uses a location-scoped plugin for per-account save and switch. `PlusProfileController` owns profile persistence and background work.
- Old saved sign-in files outnumber current profiles. Those files are recovery material, not the desired account list.

## Existing sign-in workflow

Keep the user's normal sequence:

1. Sign in to OpenChamber with its device login code.
2. Select the matching CodexPlusBar profile.
3. Click **Save current sign-in**.

Saving links the existing OpenChamber credential to that profile; it does not create a duplicate. Automatic credential creation means restoring an already-saved OpenChamber sign-in when it is missing. It does not introduce a new login method or require signing in through CodexPlusBar.

Allow time to complete this sequence. On initial enablement, existing surplus credentials are reconciliation candidates. Newly observed unmatched OAuth credentials after that baseline receive a 15-minute capture grace period. Show “Waiting for Save current sign-in” during that period. Persist pending credential IDs and first-seen times so restarting the app neither shortens nor resets the grace period. A successful save binds the new credential and ends its grace period; an unmatched credential becomes a removal candidate after the period expires. The active-account idle rule still applies. The mirror can therefore be temporarily incomplete while an account is being added.

## User-visible behavior

Provide one persistent **Automatically sync OpenChamber** setting, enabled for this requested integration. Explain it with: “Keep OpenChamber's OpenAI logins matched to your saved Codex profiles, including removals.” Disabling it stops future reconciliation.

While enabled:

- Launch and successfully saved profile changes schedule sync. Coalesce repeated edits for one second. A lightweight 60-second retry catches OpenChamber reopening and changes made in OpenChamber.
- Retain matching saved logins, restore missing logins when a supported saved OpenChamber OAuth sign-in exists, update their display labels, and remove surplus OpenAI OAuth logins.
- Removing a profile removes its corresponding OpenChamber login. Adding an OpenChamber-only login does not create a CodexPlusBar profile; if it remains unlinked after its capture grace period, remove it on reconciliation.
- Membership follows persisted Codex profiles, regardless of temporary search, sorting, tags, usage errors, or expiry display. Expiry itself does not delete a profile.
- Show one compact sync status and a **Sync now** action in existing profile-manager controls. Missing credentials produce a per-profile “OpenChamber sign-in needed” state. Report partial sync honestly, for example “9 of 10 profiles linked; 1 needs sign-in.”

### Visible Remove action

In the selected profile's detail action row, place a labeled **Remove** button with a trash icon immediately after **Refresh**, before **More**. The row order is **Open Codex/Claude** (when available), **Refresh**, **Remove**, **More**. Use the existing compact button styling, destructive role, and an accessibility label of “Remove profile.”

Move the existing Remove profile action out of the More menu and reuse its selected-profile removal operation. Preserve the existing direct-click behavior, without adding a confirmation step. A successful catalog removal schedules the OpenChamber reconciliation. Verify fit at the existing supported window widths.

This manages saved OpenAI OAuth logins in the verified local OpenChamber backend. Other providers, API keys, and environment connections are outside this login-list mirror. The backend's saved connections are shared with any clients using that same backend.

## Identity and credentials

Use OpenAI account ID plus user ID as the logical identity; retain native credential IDs as bindings. Profile UUIDs identify local rows. Keep the existing Save current sign-in identity checks: email can validate an otherwise unbound profile only when its identity is unambiguous, and the resolved identity must be persisted before pruning. Background matching uses saved identities rather than silently saving a newly signed-in account. Never use display-label changes as proof of a different account.

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
2. Resolve saved identities and repair their native credential bindings; restore missing eligible credentials before removal. Track newly observed unmatched credentials through the capture grace period.
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
- Add the preference and compact status to existing settings/profile-manager patterns. Move the existing Remove action next to Refresh in `AccountWindowView.actionPanel`.

## Verification

Meaningful tests must cover restoration, deletion, relabeling, duplicate identities, preserved active selection, active-account removal after idle, intentional empty catalogs, missing/read-failed catalogs, failed saves, concurrent edits, partial network failure, uncertain create/delete outcomes, stale snapshots, unsupported OAuth methods, and unrelated providers/API keys. Include device-login capture: a newly observed login survives until saved or its grace period expires, a restart preserves that deadline, and saving it does not create a duplicate. Visually verify the directly accessible Remove button and exercise removal with a disposable profile.

Use an isolated OpenCode server and synthetic credentials to verify native API semantics, including `activate: false` and deletion. Run the repository's `make test` and `make build`, confirming the actual Swift Testing count. Verify live UI status and resulting account inventory when the completed integration is enabled; report profiles that still require OAuth sign-in rather than claiming a complete ten-account mirror prematurely.
