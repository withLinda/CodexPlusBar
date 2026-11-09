# CloudKit account sync for the notarized DMG

Date: 2026-11-09
Status: Approved by the user on 2026-11-09

## Intent and approved direction

The user uses CodexPlusBar on several Macs and wants automatic account synchronization instead of repeated export/import. Distribution is a Developer ID–signed, notarized DMG. The user cancelled TestFlight preparation and selected syncing saved login sessions as well as profile details, passwords and 2FA secrets.

The in-chat design and this written specification were approved on 2026-11-09. This document defines the implementation contract.

Success means changes appear on another Mac signed into the same iCloud Apple Account, offline edits survive, and incoming data never silently replaces a working active login. Saved sessions are transferable snapshots, not a guarantee that providers will accept one OAuth refresh token concurrently on multiple Macs.

## Platform and distribution

- Minimum macOS version: 14.0. Swift version: 6. Strict concurrency and warnings-as-errors remain enabled.
- Bundle ID: `com.linda.CodexPlusBar`. Developer team: `2Z8N5KTWQZ`, as observed in the installed app's signature.
- Proposed CloudKit container: `iCloud.com.linda.CodexPlusBar`. Confirm/register it in the developer account during provisioning.
- Use CloudKit's private database, a custom zone named `AccountSyncV1`, and `CKSyncEngine`.
- Use CloudKit, remote notifications, and the application's own Keychain access group. Authorize restricted entitlements with a matching Developer ID provisioning profile. App Sandbox is not a dependency of this design.
- A release uses the Production CloudKit environment and the corresponding push environment; provisioned development builds use Development. These environments are deliberately separate.
- Build configuration checks must reject a cloud-enabled release with a missing/mismatched profile, container, environment, team, or signing identity. An ad-hoc test build must not instantiate a live CloudKit container.
- Package with Developer ID Application signing, hardened runtime, notarization and stapling. App Store Connect is not part of this workflow.

## User experience

Add an `iCloud Sync` section to the existing Settings view. Use the existing native controls and theme styles.

- `Sync accounts with iCloud` is off until enabled on each Mac.
- `Include saved login sessions` defaults to on when sync is first enabled, matching the requested scope, and retains the user's later choice. Explain provider expiration and refresh-token rotation. Enabling session sync includes credentials and cookies already saved by CodexPlusBar.
- Show current state, last successful sync time and a `Sync Now` action.
- States distinguish off, initial merge, syncing, up to date, waiting for network, waiting for iCloud sign-in, waiting for iCloud Keychain, paused for backup/restore, and an actionable error. Failed/deferred uploads are not reported as up to date.
- Settings remain usable while offline. Local account editing remains available when CloudKit is unavailable.
- A profile can show saved sessions available from another Mac. Importing one is an explicit action associated with that profile and source Mac. Existing Switch/Repair actions perform live installation and verification.
- Disabling sync stops new cloud work and retains both local accounts and existing cloud copies. Deleting a profile while sync is enabled propagates its deletion.

## Data contract

### Profile records

Use the existing profile UUID as the stable sync identity. A CloudKit record is one logical profile, not an upload of the whole local catalog.

The synchronized user-owned fields are provider, label, email link, password, 2FA secret, phone number, notes and tags. Preserve unknown provider identifiers as inactive data, matching the existing catalog behavior. Creation time is stable metadata. Profile ordering is a separate versioned ordered list of UUIDs so remote normalization does not become another local reorder.

Subscription-expiry and detected-account metadata can be carried as dated observations. Newer verified local observations take priority over older cloud observations. A remote observation is not evidence that this Mac has a valid login.

The following are device-local: WebKit store UUIDs, Chrome paths, native OpenCode credential IDs, native selected-account state, live usage/check results, in-flight operation receipts, selector ownership/maintenance state and cloud sync cursors. Creating a profile from cloud data allocates a fresh local WebKit store UUID.

Matching uses profile UUIDs. Never merge profiles merely because their labels or email addresses match. Existing exports preserve profile UUIDs, which supports matching already-transferred accounts. Independently created duplicates remain visible for deliberate user cleanup.

### Session snapshots

Store browser-cookie, Codex desktop and OpenChamber snapshots separately from the profile record. Each has a profile UUID, source-device UUID, kind, source revision, capture time and credential identity. Native credential bindings and file paths do not cross devices.

- Browser snapshots contain only the provider-scoped cookies accepted by the existing `BackupCookie` validation, including chunked session-token families. Expired cookies are excluded at adoption.
- Desktop snapshots use the latest resolved credential from `CodexSignInVault`, including the evidence needed to reject consumed generations.
- OpenChamber snapshots use the latest resolved `OpenCodeCredentialValue`; preserve supported native metadata but rebuild its credential ID on the destination through existing APIs.
- Capture occurs after durable successful local save/refresh/repair and during an explicit sync reconciliation. Use existing operation serialization, not arbitrary simultaneous file reads.
- Remote snapshots are retained in a separate local inbox. Receiving them does not write `.codex/auth.json`, alter another application's active connection, or overwrite the destination's working saved snapshot.
- Adoption validates profile identity, schema and generation. Use the existing credential verifier and installation flow. Persist rotated credentials before cancellation or a following network operation, as the existing recovery code requires.
- For browser adoption, replace the provider cookie family as a unit in a fresh retained WebKit store; validate the account identity before publishing it as the local runtime. Seed a dedicated Chrome profile through its existing controlled CDP lifecycle when the user opens that adopted session. Never manipulate the user's ordinary Chrome profile.
- Receiving a snapshot does not renew it. A rejected session offers Repair; a network error remains a network error.

**OAuth concurrency boundary:** Codex and OpenChamber can refresh tokens outside CodexPlusBar. CloudKit locks cannot serialize those external writers. Source revisions identify snapshots; they do not make cloned refresh tokens safe. A transfer may require a fresh per-Mac authorization. The UI and tests must not imply guaranteed permanent or simultaneous sign-in.

Whole Chrome directories, caches, SQLite databases and backup archives are not the sync transport. The existing encrypted backup remains the full installation-transfer mechanism.

## Encryption and keys

Encrypt profile payloads and session snapshots locally with CryptoKit AES-GCM and a random 256-bit key. Store only encrypted payloads plus minimal routing/schema/key identifiers in CloudKit. Associate the authenticated ciphertext with the container, zone, record ID, kind, schema version and key ID to reject record substitution.

Keep application-owned encryption keys in synchronizable iCloud Keychain items using the data-protection Keychain and a dedicated service/access group. Do not change the existing `Codex Auth` Keychain entries owned by the desktop integration.

Each writer can create a uniquely identified encryption key. Records carry that key's UUID, allowing simultaneous first-time setup without two Macs competing to overwrite one shared key item. Bind key lookup and local sync state to the current CloudKit user identity and environment. Retain keys while referenced records exist.

CloudKit and Keychain delivery are independently asynchronous. If a record arrives before its key, retain the encrypted record and show `Waiting for iCloud Keychain`; do not erase the local profile or upload an empty replacement. Retry on activation, manual sync and bounded backoff. Never substitute a new key for a missing key ID.

Use encrypted CKAssets for payloads, with a 16 MiB per-payload limit and schema validation before allocation/adoption. An oversized or invalid record produces an item-specific error and does not erase valid local data. Local staging files have mode 0600 inside mode-0700 directories and are cleaned after operations. Tokens, cookies, passwords, key material and decrypted payloads never enter logs, URLs or test fixtures.

## Merge and persistence semantics

- Local storage remains usable offline. Maintain a separate device-local sync journal containing the committed projection, queued mutations, CloudKit system fields, encrypted inbox and serialized CKSyncEngine state.
- A successful local catalog write precedes publication. Failed local persistence does not enqueue cloud changes. Reconcile the committed catalog with the journal after restart to recover a crash between those steps.
- Version each editable profile field with a Lamport counter and source-device UUID. Increment beyond counters already observed. Distinct field edits merge independently; same-field conflicts select the greater `(counter, deviceUUID)` deterministically. Wall-clock time does not decide user edits.
- Treat cleared optional fields as explicit versioned values. Absence in an older schema is not a deletion.
- Tags are one versioned field in v1. Profile ordering is one versioned list; locally missing entries are filtered and new entries append deterministically by creation time and UUID.
- Represent deletion with a durable tombstone. A deleted profile is not resurrected by a stale offline update or an older session snapshot. Delete its remote session payloads after the tombstone is durable; retain the tombstone to recognize returning offline devices.
- An explicit restore/import may recreate a previously deleted account with a new UUID; remap local references consistently. Ordinary remote delivery never performs this recreation.
- On `serverRecordChanged`, merge the server record with pending local mutations, preserve its CloudKit system fields, then retry. A successful acknowledgement clears only the exact local generation it sent, not edits made during the request.
- Persist fetched data before advancing its durable fetch state. Remote application is tagged as remote so it does not create an upload loop.
- Batch through CKSyncEngine's supported record-zone batch initializer and honor send scope and per-item outcomes. Retain pending work for transient errors and honor CloudKit's retry scheduling.
- Partition journal, inbox and keys by iCloud user and environment. On account change, cancel the old engine, reject late results from its epoch, pause sync and require explicit enablement for the new account before uploading local data.

## Integration boundaries

Create a focused `Sources/CloudSync/` subsystem rather than putting CloudKit behavior into the existing large profile controller.

- `CloudProfileDocument` and merge helpers: portable data, clocks, ordering, tombstones and deterministic merge; no CloudKit or UI dependencies.
- `CloudSyncJournal`: crash-safe private persistence, owner/environment partitioning and dirty-generation tracking.
- `CloudPayloadCipher` / `CloudKeyStore`: authenticated encryption and synchronizable application-key access.
- `CloudKitAccountSync`: CKSyncEngine delegate, record mapping, asset staging, acknowledgements and account lifecycle.
- `CloudSessionSnapshotService`: capture/adoption through current vault, browser and native credential services and their operation gates.
- `CloudSyncCoordinator`: serialized connection between committed local state, cloud changes, backup pauses and session capture.
- `CloudSyncPresentation`: observable status/actions consumed by Settings and profile session actions.

`PlusProfileController` gains a narrow post-commit publication hook and an explicit remote-merge entry point. Apply remote changes against the latest catalog, not an older snapshot held across an await. Preserve local draft ownership and active operations. `AppRuntimeController` starts sync after startup restore work, and stops it during termination.

## Backup, restore and local integrations

Cloud sync participates in the existing transfer pause: finish in-flight durable writes, cancel/defer network application, and stage fetched changes until transfer ends. Export remains a local encrypted snapshot and does not require iCloud.

After a full restore, leave cloud publication paused and show that enabling sync will merge restored accounts with iCloud. Restored absence alone must not generate remote deletions. Re-enablement uses an initial merge; an explicitly restored tombstoned account gets a new UUID. Device identity, cloud journal and cloud keys are not replaced by the account archive.

Keep OpenChamber automatic reconciliation and selector maintenance coordinated with remote profile changes. A remote profile removal must go through the same pending-operation and selected-credential protections as a local removal. Do not feed an incomplete cloud page to the existing reconciliation logic as a complete empty catalog.

The sync of account records does not automatically switch the user's currently active desktop/OpenChamber account. Explicit session adoption and the existing Switch action own those changes.

## Provisioning and release deliverables

Add entitlements/configuration for development and Developer ID Production builds, plus a packaging preflight that inspects the embedded profile and the final signed entitlements. Register the explicit app ID/container and create/download an appropriate Developer ID profile through the user's Apple developer account. Use saved signing/notarization identities where applicable; request secrets only through the private secret tool if necessary.

Deploy the schema to Production before distributing the cloud-enabled DMG. Include a release checklist/runbook for signing, profile embedding, schema deployment, notarization, stapling and fresh-Mac sync validation. A successful local build or notarization alone is not evidence of functional iCloud sync.

## Verification and acceptance

1. Deterministic two-replica tests: offline edits, concurrent same/different-field edits, clock skew, clear versus missing fields, ordering convergence, delete versus stale update and explicit restore.
2. Persistence tests: interruption before enqueue, during asset staging, after remote application and before state save, plus acknowledgement racing a newer local edit.
3. Encryption tests: roundtrip, wrong key, tampering, record substitution, delayed key arrival, concurrent key creation, size bounds and owner/environment separation.
4. Session tests: chunked/unchunked cookies, expired cookies, wrong identity, stale token generations, valid local-session preference, native metadata preservation and new destination binding.
5. Lifecycle tests: account switch during an in-flight fetch/send, offline/retry/quota errors, disabling sync, backup pause/restore and startup without cloud entitlements. Use injected cloud and Keychain adapters with synthetic data.
6. Run the repository's strict build and meaningful Swift Testing suite, verifying the nonzero final test count. Existing real-runtime integration checks remain opt-in and isolated.
7. Inspect Settings and session actions in the native preview with synthetic profiles. Verify enable/disable, waiting/error states and keyboard/accessibility behavior.
8. Provisioned two-Mac test under the same iCloud account: first union merge, edits both ways, offline recovery, deletion, delayed Keychain keys, session snapshot transfer, browser adoption and explicit native adoption/repair. This requires the second Mac and user authorization where the provider requests it.
9. Verify final Developer ID entitlements/profile, notarized DMG and first launch on another Mac. Report local test results, live CloudKit results and cross-Mac results separately and truthfully.

## Delivery sequence

Plan the work in coherent, independently testable units: merge/journal and cryptography; CloudKit transport/lifecycle; app integration and session capture/adoption; Settings and restore behavior; provisioning and release validation. Session transfer is part of the requested delivery, not an implicitly deferred feature.

## References

- [Apple: Developer ID certificates and CloudKit support](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple: CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- [Apple: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/)
- [Apple: Secure Keychain syncing](https://support.apple.com/guide/security/secure-keychain-syncing-sec0a319b35f/web)
- Current local integration evidence: `Sources/Services/CodexSignInStorage.swift`, `OpenCodeSignInSnapshotStore.swift`, `Sources/Backup/BackupSessionBridge.swift`, and `Learnings.md` token-rotation notes.
