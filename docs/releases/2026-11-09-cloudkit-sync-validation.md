# CloudKit sync validation

Updated 2026-11-10. Branch: `feature/cloudkit-account-sync`. Distribution: Developer ID DMG. **Cross-Mac acceptance remains pending.**

## Local verification

- Tasks 1–8 retain their completed targeted verification and reviews. Task 9 commit: `021dbc8`.
- Latest integration/review-fix run: **54 tests in 3 suites passed**, `CloudSyncEndToEndTests`, `CloudSyncPresentationTests`, `CloudKitAccountSyncTests`. Log: `task11-final-focused.log` in the session's temporary evidence directory. No full test run was repeated, per user instruction.
- Earlier Task 9 run: **33 tests in 2 suites passed**, presentation/coordinator, plus strict Release build.
- Release-preflight Python checks: **5 tests passed**, including subcases rejecting absent/expired/future/wrong-team/wrong-platform profiles, ad-hoc or wrong certificates, missing runtime/timestamp, wrong app/container/environment/push/Keychain, sandbox/debugger entitlements.
- Provisioned **CloudDevelopment build passed** and actual artifact preflight passed. Ordinary Debug/Release and synthetic preview remain cloud-disabled.
- Universal strict **CloudProduction archive passed**; both Mach-O slices independently listed as `x86_64 arm64`.

The two-replica harness uses real coordinators, journals, merge/apply logic, AES-GCM, record codecs, transport and a real isolated native saved-login vault. Only CloudKit service/engine delivery, Keychain delivery and external provider verification are synthetic. It checks initial union, local browser-ID preservation, offline conflicting/disjoint edits, explicit clear, create/order, stale-draft save preservation, missed acknowledgement plus restart, offline deletion dominance, no settled upload echo, delayed keys, receipt without installation, explicit native import without activation, restore pause/restart/re-enable, and owner replacement. It does not replace live two-Mac acceptance or prove every CloudKit server ordering.

## Native UI

Inspected real native screenshots of compact light/dark Settings and account inbox, 135% text, long source name, two sources, empty sessions, import feedback, network/account/Keychain waiting, restore pause and Repair error. Existing Switch/Repair actions remain the activation/recovery paths.

`scripts/verify_cloud_actions.swift` passed accessibility labels and AXPress. A separate real **Tab/Space** run reached and invoked Import. System Keyboard navigation was temporarily enabled and restored to its original `AppleKeyboardUIMode=0`. These actions used the isolated synthetic preview, not installed credentials. VoiceOver speech itself was not exercised.

## Live Apple service evidence

On 2026-11-09, isolated provisioned Development and Developer ID Production probes passed:

- iCloud account availability and private-zone encrypted CKAsset save/readback.
- App-owned synchronizable data-protection Keychain add/read/delete.
- Production APNs token registration and silent private-zone subscription save/readback.
- Minimal `CPBEncryptedRecordV1` schema deployed and independently exported from Production.

Temporary probe zones, subscriptions and keys were removed. This is evidence of authorization/schema/local Keychain access, not cross-device Keychain or push delivery. See [the release runbook](cloudkit-dmg-runbook.md) for identifiers, profiles and commands.

## Final author self-review

Performed personally under the user's no-subagent instruction. Earlier independent Task 1–6 reviews stand; final integration review is author self-review.

Checked the five plan review focuses against source: schema/opaque-field quarantine and send blocking; missing/unreadable catalog refusal before deletion inference; ciphertext durability before cursor commit; durable restore pause and startup admission; field-diff draft saving. Also checked owner/epoch fences, exact revision retry, native consumption/recovery ordering, browser catalog-before-runtime handoff, opt-out, profile/signature authorization and packaging.

Fixed findings with observed failing tests:

- **First-use zone ordering:** fake engine originally saved the zone immediately, masking production's queued zone creation. Queue-faithful replica tests failed, then passed after explicitly sending the database save before fetching.
- **Opt-out during import:** presentation's busy guard blocked consent withdrawal. Barrier tests failed on both sync and session opt-out, then passed with immediate cancellation/revocation and counted in-flight operations. Settings permits turning off while busy.
- **Source Mac label:** exported snapshots used the constant `Mac`. Replica assertion failed, then passed with an injected source-name boundary and bounded local Mac name in production.
- **Timestamp ownership:** previous owner's last-success must not label another owner's partition. RED→GREEN presentation regression clears/reloads it while ordinary disable retains the timestamp.
- **Draft admission:** display availability must use the same adoption gate as execution. RED→GREEN covered dirty drafts; explicit post-save/remote-refresh ownership updates prevent stale protection.

No unresolved Critical/Important local code findings were identified in this review. Live cross-Mac acceptance is still required. Deferred minors: further split the large transport/coordinator files if future maintenance needs it; best-effort browser cleanup can retain orphaned local data after a crash. Historical fixture-isolation/receipt-only concerns were addressed by isolated fixtures and connected destination adapters in later tasks.

## Decisions carried forward

- Use planned record names directly in the unshipped journal. Cost if wrong: synthetic fixtures need regeneration.
- Compact completed catalog plans/ciphertext and superseded local full session bodies, retaining tombstones, clocks, receipts, exact in-flight ownership and consumption evidence. Cost: less historical diagnostic data; current/cloud copies remain.
- Read-only OpenChamber capture uses the shared operation gate without selector maintenance. Cost: future live-native capture must introduce coordination that does not silently pause Auto.
- A consumed source is only an exact destination-recovery locator. A distinct persisted replacement must pass current checks before provider use. Cost: conservative refusal may require Repair.
- Persist returned refresh/native-create recovery evidence even after cancellation; require renewed authorization before later installation. In-flight accepted network requests cannot be revoked. Ambiguous native rotation requires Repair.
- Centralize native adoption regression cases in the native-adoption suite; keep existing native suites as affected regressions. Cost: organization only.
- Keep browser recovery local to profile/store, exclude it from portable backups, and invalidate on Clear/new sign-in/newer cookies. Preserve committed/uncertain catalog recovery. Cost: conservative invalidation may require fresh sign-in.
- Preserve approved native cards and existing controls. Synthetic model statuses and provider verification cannot establish live user/provider behavior.
- Follow the user's targeted-testing and author-self-review choices. No new full-suite or subagent runs.
- Resume packaging from an unchanged verified archive into a fresh staging directory; validate architecture with `lipo -archs` because this toolchain's `-verify_arch` rejected the valid input. Cost: packaging depends on the explicit architecture-set check.

## Two-Mac acceptance — pending

Use the final cloud-enabled DMG on a second Mac signed into the same iCloud account, with Passwords & Keychain enabled. Installation/replacement is a separate user action.

- Enable sync on each Mac: confirm initial union and independent local browser IDs/native selection.
- Edit/clear details on both, go offline, make conflicting edits, reconnect, and verify convergence.
- Delete on A while B is offline; reconnect B and verify no resurrection.
- Observe encrypted-key arrival or Keychain waiting recovery and automatic Production push delivery. Also exercise activation and Sync Now.
- Save browser, Codex and OpenChamber logins on A; observe summaries only on B, explicitly import, confirm a working local login wins, then use Switch and Repair as needed.
- Turn sync/sessions off during pending work, re-enable, and verify retained copies plus new-work gating.
- Restore a backup, restart, verify publication stays paused, then explicitly enable and confirm union.

Record build/environment, pass/fail/pending and observations without tokens, cookies or secret values. Do not mark the feature accepted until these checks pass.

## Packaged artifact

Artifact: `build/cloud-releases/release-20261110T102620Z-Q8OKmj/CodexPlusBar-1.6.2-cloud.dmg` (unpublished branch build, version 1.6.2/build 22).
Release tooling commit: `0c36c8a`. Verified application source and integration checks: `0f8bc40` (committed after building the same source).

- Universal source archive: `build/cloud-releases/release-20261110T102259Z-pVpbXW/CodexPlusBar.xcarchive`.
- Developer ID: Linda Fitriani (`2Z8N5KTWQZ`), Production CloudKit and APNs; embedded profile validated before and after packaging.
- App notarization **Accepted**: `f6051e59-3740-45dc-a9b1-9ebce77dd52a`.
- DMG notarization **Accepted**: `fa172484-0cf2-47a4-8fd8-df109b32ebcd`.
- App and DMG stapled, then tickets validated sequentially. Gatekeeper accepted both with `source=Notarized Developer ID`.
- Mounted DMG read-only, verified packaged app signature/profile/entitlements and app ticket, then detached successfully.
- Final checksum verified after stapling:

```text
217c61309ee74d42dcffc50686d6cb8f0cc5f750739808812e0c614c4f1e2525  CodexPlusBar-1.6.2-cloud.dmg
```

The `.sha256`, `architectures.txt`, preflight results and both notarization JSON results are beside the DMG. Full packaging log: `cloud-notarization-final.log` in the session's temporary evidence directory. The app was not installed, published, or substituted for the current `/Applications` copy.

## Version 1.7.0 release artifact

The earlier 1.6.2 artifact above is historical. The release uses a **fresh 1.7.0/build 23** archive from `feature/cloudkit-account-sync`, with matching generated Xcode settings in all four configurations. Application code is the previously verified source; this release changes version metadata and documentation.

- Workspace: `build/cloud-releases/release-20261110T104543Z-DHDteM/`; archive: `CodexPlusBar.xcarchive`; packaged image: `CodexPlusBar-1.7.0-cloud.dmg`.
- Strict universal `CloudProduction` archive: **ARCHIVE SUCCEEDED**. Archived Info.plist verified version `1.7.0`, build `23`, bundle ID `com.linda.CodexPlusBar`, macOS minimum `14.0`; executable contains exactly `arm64` and `x86_64`.
- Five targeted Python release-preflight tests passed again. Version/build consistency and README local links/anchors verified. No full Swift suite repeated for metadata/docs changes.
- App notarization **Accepted**: `6dce42b0-d600-477f-b6e1-e9dfcefc7588`.
- DMG notarization **Accepted**: `76be0761-a8d3-419e-bb4d-12a3107e89fe`.
- App and DMG signature/staple validation and Gatekeeper passed. Actual mounted app passed Production profile, CloudKit, APNs and Keychain preflight plus staple validation; the image was detached.
- Upload copy: `github/CodexPlusBar.dmg` (7,743,896 bytes). `github/SHA256SUMS` names that stable basename and passed `shasum -a 256 -c SHA256SUMS`. Copying changed the filename only, not the notarized bytes.
- Release notes: [1.7.0.md](1.7.0.md); release URL: <https://github.com/withLinda/CodexPlusBar/releases/tag/v1.7.0>. Publication targets the exact release commit on the active feature branch.

```text
b6fbe1c759dc164b0be550b1b78a8962cab5b139015e327a2b2a8b927fb538ce  CodexPlusBar.dmg
```

`packaging.log`, `archive.log`, architecture/preflight results and notary JSON files are retained in that release workspace. Installation on either Mac and the live acceptance checks above remain separate, pending user actions.

## 1.7.1 browser storage regression

The installed 1.7.0 app reported `unsafePath` for all profile refreshes even with iCloud Sync off. `CloudBrowserSeedStore` defaulted to `CodexPlusBar/CloudBrowserSeeds`, inside the account tree that `CloudPrivateFiles.openRoot` rejects before checking existence. `PlusProfileDataService.refreshProfile` loads browser recovery before session/usage HTTP requests, so the path error blocked ordinary refresh as well as related browser actions.

The correction changes only the default recovery location to the private sibling `CodexPlusBar.browser-recovery`. It retains descriptor-relative access, ownership/permissions and symlink checks. The original production location could never pass validation, so there is no valid production recovery data to migrate. Profiles, existing browser data and native sign-ins are not moved.

Targeted RED→GREEN verification:

- Tests derive the actual default's full Application Support-relative layout and rebase it into an isolated temporary directory. The old arbitrary `seeds` fixture omitted the production conflict.
- Before the fix: 30 selected tests ran in two suites; the new default-layout test and affected service tests reproduced `unsafePath` (14 reported issues).
- After the fix: **30 tests in two suites passed**, Xcode **TEST SUCCEEDED**. Suites: `CloudBrowserSessionAdoptionTests` and `PlusProfileDataServiceTests`.
- Coverage includes no-op missing-store reads/removals, private directory/file modes, durable save/restart/remove, session→usage→expiry refresh and existing browser actions. Rejection of account-tree paths and redirected directories still passes.
- Five release-preflight Python tests passed again. No full test run and no subagents. Author self-review confirmed the minimal default-path change and isolated fixtures; provider responses are controlled, not evidence of live account acceptance.

Logs: `cloud-browser-path-red.log` and `cloud-browser-path-green.log` in the session temporary evidence directory. The corrected installer is version **1.7.1/build 24**; see [release notes](1.7.1.md).

### 1.7.1 packaged artifact

- Workspace: `build/cloud-releases/release-20261110T111956Z-TmDBmC/`; fresh strict universal archive **ARCHIVE SUCCEEDED**, exactly `arm64` and `x86_64`; Info.plist verified `1.7.1`, build `24`, macOS minimum `14.0`.
- App notarization **Accepted**: `a87df92d-f009-4b12-bf01-5a49ec36ce00`.
- DMG notarization **Accepted**: `d70ec478-4155-49c4-a125-8882421e08f5`.
- App/DMG signatures, staples and Gatekeeper passed. Read-only mounted app passed Production profile/CloudKit/APNs/Keychain preflight and ticket validation; image detached.
- Upload copy `github/CodexPlusBar.dmg`: 7,743,920 bytes. `github/SHA256SUMS` verified after all stapling. `packaging.log`, notary JSON and archive/preflight evidence remain alongside the image.

```text
6924321d74f3ebc5e9fd6eebd89bba89febaf267749bb073dd34ff03f67171c1  CodexPlusBar.dmg
```

## 1.7.2 iCloud enablement regression

The installed 1.7.1/build 24 passed Production profile/CloudKit/APNs/Keychain preflight, and system logs showed successful private-database requests. Nevertheless, enabling sync immediately disabled it and displayed “Waiting for iCloud sign-in.” Preferences retained an owner consent entry but `enabled=false`; the journal had not initialized.

A signed fresh-engine probe confirmed `accountStatus == .available` and an initial `.signIn(currentUser:)` matching the verified owner. `CloudKitEngineDelegate` incorrectly mapped every SDK account event to `.accountChanged`; the transport invalidated its epoch and the coordinator disabled consent. The correction passes the verified `CloudOwner` into the delegate and ignores only that matching sign-in. All other account changes retain the existing invalidation/drain/consent path, including sign-out and switches back to the verified owner.

Targeted verification:

- Extracted a delegate handler for the SDK's constructible `AccountChange.ChangeType`, preserving the original unconditional invalidation before running RED. The SDK's containing event has no public initializer.
- RED: **75 tests in two suites**, six issues in the two new same-owner regressions: transport `.notStarted`, disabled Settings, non-resumable consent, uninitialized journal, and disabled/ownerless restart.
- GREEN: **82 tests in three suites passed**, Xcode **TEST SUCCEEDED**: `CloudKitAccountSyncTests`, `CloudSyncCoordinatorTests`, `CloudSyncPresentationTests`.
- Tests exercise the real delegate/transport and a real coordinator/presentation with isolated storage and synthetic network delivery. They cover startup/repeated matching sign-in, restart consent, mismatched sign-in, sign-out, both switch directions, late matching sign-in/state rejection after invalidation, and retained dirty work.
- Signed live adapter probe linked the actual app object files from the verified Debug build (excluding the app entry point) into an isolated executable, then forwarded complete SDK events to the production delegate. Result: **one matching sign-in, zero invalidations, four state updates, one completed empty-scope fetch**. Its unique subscription was deleted. It did not read/write account records or touch local profiles.
- Five release-preflight Python tests passed. Author self-review checked verified-owner propagation, default invalidation of unknown future cases, owner/environment gating before delegate construction, transport token/drain behavior, and Settings persistence. No new review findings; no full tests or subagents.

Evidence: `cloud-account-event-red.log`, `cloud-account-event-green.log` in the session temporary directory; signed probe source/build helper and `adapter-probe.log` in `build/cloud-account-probe/`. The fixed installer is **1.7.2/build 25**; see [release notes](1.7.2.md). Live two-Mac acceptance remains pending.

### 1.7.2 packaged artifact

- Workspace: `build/cloud-releases/release-20261110T132700Z-ghy9pt/`; fresh strict universal archive **ARCHIVE SUCCEEDED**, exactly `arm64` and `x86_64`; Info.plist verified `1.7.2`, build `25`, macOS minimum `14.0`.
- App notarization **Accepted**: `c7de4a98-5ef3-43f6-ae96-8a37a05ecc6f`.
- DMG notarization **Accepted**: `3101816f-cd53-4e1e-9706-2a9eb011de39`.
- App/DMG signatures, staples and Gatekeeper passed. Read-only mounted app passed Production profile/CloudKit/APNs/Keychain preflight and ticket validation; image detached.
- Upload copy `github/CodexPlusBar.dmg`: 7,746,438 bytes. `github/SHA256SUMS` verified after all stapling. `packaging.log`, notary JSON and archive/preflight evidence remain alongside the image.

```text
3f24d637e4e63208ec0e16f4c53ecdc3cacf786d9886678b94a3104c4c8bc5f1  CodexPlusBar.dmg
```

## 1.7.3 overlapping-send investigation

The user reported 45 profiles on this Mac and 33 overlapping profiles on another, both enabled on 1.7.2 but unable to finish syncing. Read-only inventory found 45 encrypted profile records and one order record, with no sessions uploaded. The installed journal retained 122 dirty saved-session records. Apple daemon logs showed asset upload failures with `CKInternalErrorDomain:3002`.

Investigation used actual production transport/codec/delegate objects linked into signed disposable probes. Read-only fetches passed for fresh and cloned journals, automatic sync, and the complete coordinator with a private copy of the actual 45-profile catalog and device preferences. The probe also used the production executable name. These checks did not reproduce a download or catalog-apply failure; earlier installed fetch cancellations alone do not establish one.

### Confirmed upload cause and correction

Apple documents each `didSendChanges` as the completion of its own request, and requires CKAsset source files to survive the upload. Manual and automatic requests can overlap even though delegate events are serialized. The transport discarded all flights on every send completion. An empty request could therefore delete another request's files and lose its acknowledgement ownership.

- Deterministic RED: two new targeted tests produced four expected issues, including deleted/unreadable files and re-admission while another request remained active.
- Live RED: in a disposable Production zone, a real 122-record send overlapped a real empty-scope send. The latter completed with zero item results and **zero source files remaining**. All122 failed: `CKErrorDomain:16` with underlying `CKInternalErrorDomain:3002`; the outer request returned partial failure (`CKErrorDomain:2`). This matches the installed daemon failure.
- Correction: forward SDK will-send events and count active sends per engine epoch. Per-record outcomes still release only their exact flight. A request completion releases unmatched flights only when all started sends have completed. Existing cancellation drain remains the shutdown boundary.
- Live GREEN: the same event ordering retained **122 source files** after the empty request completed; **122 saves, zero failures, zero dirty generations**. An additional live run downloaded all122 records and verified exact decoded-body equality using the production codec/AES-GCM. Every disposable zone/subscription was removed.
- Initial targeted GREEN: **70 tests in three suites passed**, including transport, session snapshots, and the existing end-to-end scenarios.

### Confirmed status cause and correction

The new45/33-profile/122-session scenario successfully transferred every profile and session but exposed both replicas remaining Pending. Authenticated saved-session receipts intentionally remain received while awaiting explicit import; `refreshStatus` incorrectly required them all to be applied. A separate small RED test reproduced both incorrect statuses. Only received, transport-processed session envelopes now count as settled. Catalog application, missing-key/quarantined input, restore, dirty work and errors retain their existing success gates. Explicit import and native activation remain separate actions.

Evidence is in the session temporary directory: `cloud-173-overlap-red.log`, `cloud-173-overlap-green.log`, `cloud-173-inbox-status-red.log`, `cloud-173-targeted-final.log`. Signed live probe sources/results are under ignored `build/cloud-account-probe/`. The live asset reproduction used synthetic profile bodies; actual saved-session capture, encryption, download, summaries and restart are exercised by the45/33 replica scenario. No real local profiles, credentials, or cloud account records were changed by the probes.

Author self-review checked paired event ordering, epoch resets, per-item exact-generation acknowledgements, missing-result retention, cancellation drain, retry admission, and receipt authentication/application gates. No subagents or full-suite runs were used. Live physical two-Mac acceptance remains pending.

Final targeted GREEN: **79 tests in four suites passed**, Xcode **TEST SUCCEEDED** (`CloudKitAccountSyncTests`, `CloudSessionSnapshotTests`, `CloudSyncEndToEndTests`, `CloudSyncPresentationTests`). The45/33 scenario transferred all122 saved sessions, preserved existing browser-store IDs, reached Up to date on both replicas, and stayed settled after fresh-controller restart without additional cloud writes. Debug runtime was322seconds, dominated by full synthetic fetches and durable journal/asset revalidation. The initial120second interrupted attempt was discarded; the final run completed uninterrupted. Only known toolchain AppIntents-metadata and host linkd diagnostics appeared, with no compile errors or test issues.

### 1.7.3 packaged artifact

- Workspace: `build/cloud-releases/release-20261110T141010Z-5zLoKs/`; strict universal archive **ARCHIVE SUCCEEDED**, exactly `arm64` and `x86_64`; Info.plist verified `1.7.3`, build `26`, macOS minimum `14.0`.
- App notarization **Accepted**: `36401c96-cb44-4d8f-a028-68a95d1f9c35`.
- DMG notarization **Accepted**: `3076822f-dbf0-49ae-b1dd-a67cd3ff72f1`.
- App/DMG signatures, staples and Gatekeeper passed. Read-only mounted app passed Production profile/CloudKit/APNs/Keychain preflight and ticket validation; image detached.
- Five release-preflight Python tests passed. Upload copy `github/CodexPlusBar.dmg`: 7,747,071 bytes. All packaging logs and notary JSON remain with the artifact.

```text
74506ef3add4896c73a7ec1366f80237e1e54a8fe23d0e339c3cab95bebc48a2  CodexPlusBar.dmg
```

## 1.7.4 normal-launch download and recovery crash

The user reported that Sync Now still failed on both Macs and the other app closed. Local DiagnosticReports contained three1.7.3/build26 crashes at23:14–23:17 and matching earlier1.7.2 crashes. All were SIGTRAP in CloudKit. Symbolication using the matching1.7.3 archive UUID identified `CloudKitEngineDriver.fetchChanges` ← `CloudKitAccountSync.fetchChanges` ← `restartIfDesired`. Unified logs recorded the exact fatal assertion: “Cannot await a call into CKSyncEngine from within a delegate callback ... Try performing this in a detached Task.” The recovery began30seconds after the failed fetch. The currently installed application subsequently reported1.6.2/build22; it was not replaced or modified during investigation.

### Reproduce the initiating failure

Copying the whole actual private sync directory, catalog and device preferences into disposable storage still passed when the signed probe was started as a command-line executable. Using the same production objects, real driver, production bundle/executable name and **LaunchServices (`open -n -W`)** reproduced the installed failure:

- CloudKit delivered46 records (45 profiles plus order).
- Direct reading of the granted CKAsset file succeeded (the sampled file was1077bytes, user-owned, mode0600, single-link).
- Opening its `CloudKit` parent directory failed with `EPERM`. Every production codec envelope read failed at the descriptor-relative parent walk. The transport therefore invalidated the cursor/epoch and scheduled storage recovery.
- Awaiting that recovery in the GUI probe reproduced CloudKit's exact fatal assertion. Ordinary `Task` had retained the SDK's delegate task-local guard despite the asynchronous delay.

The previous signed CLI probes had a broader file-access context; their success did not establish normal application behavior. The previous investigation also failed to inspect existing crash reports. Both omissions are now explicit release-validation requirements.

### Narrow corrections

- CloudKit-owned input is opened directly using Darwin `O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC | O_RDONLY`. This kernel flag rejects symlinks at **every** path component without requiring directory-open permissions. The shared descriptor reader preserves bounded allocation/streaming, regular-file, single-link and current-user checks. Account-tree exclusion remains. Local storage still uses its existing private descriptor-relative walk, permissions, locks and fsync rules.
- Detach the four engine-affecting follow-up task roots: cancellation drain, expired-token restart, timed network/key retry, and storage recovery. Keep event processing serialized and awaited; keep cancellation's operation-completion barrier and token/lifecycle checks. Detaching all delegate processing or fire-and-forget inbox writes was deliberately unnecessary.

### Targeted evidence

- RED: two targeted tests with five issues: all four synthetic callback-context cases (storage, token, network, account) inherited the forbidden context; reading a file under a search-only parent failed with EACCES. The initial interrupted run used a retry clock that had not advanced and was discarded; the corrected test clock completed RED normally.
- GREEN: **88 tests in three suites passed**, Xcode **TEST SUCCEEDED**: `CloudKitAccountSyncTests`, `CloudPayloadCipherTests`, `CloudSyncJournalTests`. Existing symlink/FIFO/nonregular/oversize rejection, cancellation, old-epoch callbacks, lease retention and journal durability checks remain green.
- Signed normal-launch GREEN: complete production coordinator against private copies of actual catalog/journal/preferences fetched45 profiles, set initialized, reopened publication, and retained zero catalog receipts with no issue. Pending here reflects intentionally disabled writes for the122 retained local session records.
- Signed normal-launch recovery GREEN: inject one storage failure **inside an actual SDK fetched callback**, await recovery, then Sync Now again. The engine restarted and fetched successfully; no reentry assertion, initialized=true, issue=nil.
- Signed normal-launch roundtrip GREEN:122 synthetic Production records uploaded under overlapping sends,122 downloaded with exact production-codec decrypted-body equality, zero failures/dirty work. Disposable zone and subscription removed.
- Final affected end-to-end GREEN: **four tests passed** in `CloudSyncEndToEndTests`, including45/33 overlapping profiles,122 saved sessions, local browser-ID preservation, settled restart/no extra writes, offline merge/delete, delayed keys and explicit import. Combined with the earlier targeted run: **92 tests across four suites passed**. No full suite was run.

Evidence: `cloud-174-red.log`, `cloud-174-green.log`, `cloud-174-launchservices-red.log`, `cloud-174-launchservices-recovery-green.log`, `cloud-174-launchservices-roundtrip-green.log`, `cloud-174-replicas-green.log` in the session temporary directory. Probe sources/runner remain under ignored `build/cloud-account-probe/`. No user profile/credential data or real account records were modified. Author self-review only; targeted tests only; physical two-Mac acceptance remains pending.

### 1.7.4 packaged artifact

- Workspace: `build/cloud-releases/release-20261110T164051Z-LiwCwm/`; strict universal archive **ARCHIVE SUCCEEDED**, exactly `arm64` and `x86_64`; Info.plist verified `1.7.4`, build `27`.
- App notarization **Accepted**: `8ce494f0-e32e-4c3d-8203-1f5624e5d003`.
- DMG notarization **Accepted**: `34fd01b9-ea27-49fd-adfd-9a9998d13897`.
- App/DMG signatures, staples and Gatekeeper passed. Read-only mounted app passed Production profile/CloudKit/APNs/Keychain preflight and ticket validation; image detached.
- Five release-preflight Python tests passed. Upload copy `github/CodexPlusBar.dmg`: 7,747,675 bytes. Packaging logs and notary JSON remain with the artifact.

```text
9b1061e4a0eb91b11f26b57ad0fbffb45647b59f02f265f9f9a211e379aa28dd  CodexPlusBar.dmg
```
