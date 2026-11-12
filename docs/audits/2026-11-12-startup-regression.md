# Menu bar and Account Priority startup regression

## Evidence

- User confirmed rollback from 1.7.4 to 1.6.2 after both features stopped working.
- The running 1.6.2 process had a real, accessible status item and a fresh, trusted selector export containing 45 accounts. The extension reported Auto, no blocked reason and no maintenance holds.
- Local iCloud sync preferences remained enabled. The saved journal had no applying catalog receipt or pending restore intent.
- The 1.6.2 → 1.7.4 diff added `await cloudSync.start()` before `startBackgroundTasks()`, lazy status-item creation and the minute clock.
- Cloud startup awaits account identity, recovery, fetch, saved-session capture and upload. The extension requires a fresh publisher heartbeat; none starts until that entire operation returns.

## Reproduction and correction

An unchanged-order extraction of the production startup path made it testable with an isolated catalog and controlled cloud dependencies. Before the correction, three tests reported eight failed assertions:

- Suspending either identity lookup or fetch prevented the AppKit status item, notification setup and selector export from appearing.
- Releasing a suspended startup after shutdown restarted the publisher.
- Pending catalog recovery also hid the menu.

The correction creates the menu and starts its clock before cloud networking. The coordinator signals local readiness immediately after installing and checking its existing durable catalog-write admission. Profile refresh, native synchronization and selector publishing then start without waiting for networking. Applying receipts or restore intents keep those mutating services gated until recovery completes. Shutdown cancels the startup task and clears any deferred readiness callback.

## Targeted verification

- 44 Swift Testing tests in four suites passed, with Xcode `TEST SUCCEEDED`: `CloudStartupTests`, `CloudSyncCoordinatorTests`, `SelectorExportPublisherTests`, `MenuBarStatusItemControllerTests`.
- Startup coverage includes iCloud off, offline identity lookup, suspended identity, suspended fetch, actual profile usage/expiry export, pending catalog replay and cancellation.
- The suspended-network checks use the real profile controller, selector publisher, private atomic export store and AppKit status item; only external cloud/data responses are controlled.
- A strict universal CloudProduction archive succeeded. Developer ID signing and Production CloudKit/APNs/Keychain preflight passed.
- Full suite not run, per the user's requested scope.

Logs: `/private/var/folders/43/wvysbd0n0fs9n2724h44s4br0000gn/T/opencode/startup-{red,final-tests,archive}.log`.

Signed artifact: `build/cloud-releases/release-20261112T123907Z-szZKGy/CodexPlusBar.xcarchive/Products/Applications/CodexPlusBar.app`.

## Review and runtime follow-up

- Independent review identified two startup-concurrency gaps. Controlled regressions reproduced both: a refresh during native-operation drain could version stale fields before first-union protection, and manual menu actions could reach refresh/switch services while a saved catalog receipt was applying.
- First-union admission now pauses before attaching the bridge or awaiting recovery. A controller-level recovery gate covers manual mutations as well as background work, and the menu/manager reflect that gate. Deferred readiness cancellation is also exercised while a receipt is pending.
- After those corrections, 59 tests in five targeted suites passed; the added suite is `OpenChamberSyncControllerTests`.
- A separate cancellation regression reproduced a second refresh batch starting after bootstrap shutdown. Refresh now drains the already-admitted batch, stops before the next batch and clears remaining loading indicators. Failed RED runs printed complete failure summaries but hit the known Xcode shutdown hang; only their exact wrapper/test-host PIDs were terminated.
- The first signed candidate was launched through normal LaunchServices with existing enabled iCloud preferences. A new trusted 45-account publisher appeared in 2.73 seconds, Accessibility found the status item, and the popover opened and was captured. Account Priority remained Auto with zero maintenance holds; after fresh usage arrived it reported no blocked reason.
- That runtime candidate was stopped and the preserved 1.6.2 app reopened while review corrections were verified. Final artifact/runtime evidence follows after rebuilding.

Runtime evidence: `startup-live.json`, `startup-live-ready.json`, `startup-fixed-menu.png` in the log directory above. Review regression logs: `startup-review-red.log`, `startup-review-green.log`.

## Final source validation

- 106 tests in six affected suites passed with `TEST SUCCEEDED` (`startup-verified.log`), including `PlusProfileControllerTests` for the manual-operation and batch-cancellation changes.
- Independent re-review found no remaining reproducible blocker in first-union protection, recovery admission or deferred startup cancellation.
- Source diff whitespace checks passed. A pre-existing trailing space in the user's existing Learnings.md changes was left intact.

## Final installed validation

- Rebuilt the final source as a strict universal CloudProduction archive; signature and Production provisioning preflight passed.
- Installed the corrected local 1.7.4 build at `/Applications/CodexPlusBar.app` and launched it normally through LaunchServices.
- A fresh trusted publisher appeared in **2.73 seconds**, containing **45 account bindings**. Accessibility confirmed one status item, and its actual popover opened with profile usage and expiry rows.
- The running Account Priority service reported **Auto**, **no blocked reason**, **zero maintenance holds**, and **709 ms snapshot age** after new usage evidence arrived. No extension package change was needed.
- Previous installation retained at `build/local-startup-fix-20261112/Installed-1.6.2.app` (also copied as `CodexPlusBar-1.6.2.app` before runtime checks).
- Final signed archive: `build/cloud-releases/release-20261112T125310Z-xvx49R/CodexPlusBar.xcarchive`.
- Evidence: `startup-final-archive.log`, `startup-installed.json`, `startup-installed-menu.png` in the temporary log directory above.
- This is a local signed fix, not a new published GitHub release. Physical two-Mac sync acceptance was not part of this regression verification.

## 1.7.5 release preparation

- Bumped `project.yml` to **1.7.5 / build 28** and regenerated the Xcode project.
- Fresh versioned validation passed **106 tests in six affected Swift suites** with `TEST SUCCEEDED` and **12 Python release/signing tests**. Log: `release-1.7.5-tests.log` in the temporary evidence directory above.
- The strict CloudProduction archive contains exactly **arm64 and x86_64**, reports **1.7.5 (28)**, and passed Production profile/signature/CloudKit/APNs/Keychain preflight.
- Release workspace: `build/cloud-releases/release-20261112T130156Z-xQNhyA/`; archive: `CodexPlusBar.xcarchive`. The packaging log is `release-1.7.5-package.log` in the temporary evidence directory.
- The release pipeline requires accepted app and DMG notarization, validated staples, Gatekeeper assessment and inspection of the app mounted from the DMG. It then rebuilds Account Priority **0.1.0** from the lockfile and creates `github/CodexPlusBar.dmg`, `github/expiry-selector.zip` and `github/SHA256SUMS` together.
- `make publish-release` downloads and compares all draft uploads before publication. Keep its final verification evidence with the release workspace; publication and branch-equality checks occur after the source commit.
