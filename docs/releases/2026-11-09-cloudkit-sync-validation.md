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
