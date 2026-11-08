# Expiry selector — isolated acceptance and review

Date: 2026-11-09. Branch: `feature/expiry-selector`.
Review baseline: `e28a073dfaff17fde584bcf6063d5a90626ce7f5`.
Tasks 1–8 end at `3a18c68719c0fab6b2c18ee24d541941633c5abf`; this report accompanies Task 9.

**Result: implementation and isolated acceptance are ready for an authorized live rollout. Full live acceptance is not complete.**

Expiry is the subscription date behind CodexPlusBar's **Expires in 16d 6h** countdown. With usable quota, 17 days remaining ranks ahead of 30 days. Thirty days is descriptive, not a maximum enforced by the policy. The panel displays days/hours remaining and exposes the exact date on hover.

## Verification

| Check | Observed result |
| --- | --- |
| `npm --prefix Extensions/expiry-selector test` | 168 tests, 13 files, all passed; zero skips |
| `npm --prefix Extensions/expiry-selector run test:runtime` | 43 tests, 3 files, all passed; zero skips; includes 18 built-package cases |
| `npm --prefix Extensions/expiry-selector run typecheck` | Passed |
| `npm --prefix Extensions/expiry-selector run build` | Passed; standalone panel, plugin and service bundles |
| `npm --prefix Extensions/expiry-selector run verify:package` | Eight files; manifest, JS syntax/imports, local panel assets and fixture exclusion passed |
| `make test AGENT_NAME=expiry-selector` | Swift runner summary: 568 tests / 62 suites; `TEST SUCCEEDED`; ten opt-in checks skipped below |
| `make build AGENT_NAME=expiry-selector` | `BUILD SUCCEEDED` |
| Browser, synthetic host bridge | 16d 6h, 17d, 30d and expired countdowns; 360px without overflow; prior light/dark, increased text, keyboard, delayed acknowledgement and lost-ack retry checks |

The 43 native runtime tests are included in the 168 TypeScript total. The Swift summary is quoted as the runner reports it; it is not a claim that the skipped opt-in checks executed.

Local evidence is retained under `.superpowers/sdd/2026-11-08-openchamber-expiry-selector-implementation/`: `task-9-complete-suite.log`, `task-9-runtime-final.log`, `task-9-swift-final.log`, `task-9-build-final.log`, and `task-9-package-final.log`. The focused history regression failed in `task-9-history-red.log` before its correction. Browser capture: `output/playwright/expiry-panel-countdown.png`.

### Explicitly skipped Swift opt-in checks

1. `installedOfficialHelperStartsAndCancelsWithoutSigningIn`
2. `installedDesktopSignInCanBeSavedToAnIsolatedVault`
3. `isolatedRepairReplacesActiveAndInactiveCredentials`
4. `isolatedBulkCheckRefreshesWithoutCyclingAccounts`
5. `isolatedNativeReconciliationThroughProductionClient`
6. `installedLocalRuntimeCanBeDiscoveredReadOnly`
7. `isolatedExpiredSignInsUseControlledRefresh`
8. `isolatedServerSwitchesThroughProductionClient`
9. `installedV2BridgeCanReadCurrentConnection`
10. `authorizedBrowserIdentityEvidence`

The earlier isolated Swift bridge run and explicitly authorized two-profile, sanitized, read-only identity probe passed during this branch's work. They were not rerun in the final non-opt-in Swift command. Their scope and historical results remain in `runtime-compatibility.md`.

## Runtime and archive

- OpenChamber 2.7.0; bundled OpenCode 2.2.6.
- OpenCode binary SHA256: `ffab8fca807e87adc959b7fc3e7e9a867439dd3b6f623a2c6aeb3860f41faa45`.
- Read-only extracted host ASAR SHA256: `c4ef6a1bdd7fef0c2a388223441cc7541aae5a377cff33443d6b273e05449589`.
- Archive: `output/expiry-selector-0.1.0.zip`, relative to the repository root.
- Archive SHA256: `cf222d890d1b527bae487f6d472c75ff4a1aa30738bac06ea37ca0603046fd13` (45,411 bytes).
- Archive root: `expiry-selector/`. Its only files are `README.md`, `package.json`, `icon.svg`, `panel/index.html`, `panel/main.js`, `plugin/package.json`, `plugin/index.js`, and `service/main.js`.
- Archive inspection passed: all eight uncompressed entries match `dist/` byte-for-byte, CRCs are valid, and there are no extra files or symlinks. No source, probe, fixture, native credential store, or dependency directory is included. Inspection log: `task-9-archive-inspection.log` in the local evidence directory.

The package tests deliver actual `dist/` files through the installed host's installer/catalog/managed-config modules, using private HOME/XDG and synthetic credentials in two native locations. OS sandboxing restricts outbound traffic to loopback. Before sending fixed-port controls, the tests verify that the descriptor PID matches their own backend. Synthetic OAuth callbacks load before the selector context; traffic redirection loads afterward. The distribution excludes both helpers.

## Whole-branch review

**Method: author self-review, not a fresh-context or independent review.** The approved plan permits subagents only after the user's explicit choice; no such choice was made. Review covered the baseline-to-current branch changes, including the uncommitted Task 9 changes before this report's commit. No unresolved Critical or Important finding was identified in this pass. Independent review remains pending before integration.

The five named review-focus cases were checked deliberately: late A failures after B activation; browser identity changes during refresh; delayed native token/header publication; lost mutation responses; and plausible-looking stale/reset/restart/corrupt evidence.

| Requirement | Implementing boundary | Meaningful evidence |
| --- | --- | --- |
| Subscription expiry, both quota windows, unknown exclusion, stable tie-breaking | `src/policy/eligibility.ts`; `SelectorObservation.swift` | `policy.test.ts`; `SelectorObservationTests`; built 17-day versus 30-day case |
| Authenticated account+user matching; no display fallback as evidence | `SelectorIdentityEvidence.swift`; `AuthSessionService.swift`; `AccountCatalogService.swift`; `WorkspaceLimitService.swift` | Shared sanitized identity fixture; subject-only/conflicting/missing-user, alias, default-catalog and malformed quota regressions |
| Atomic bounded snapshot, independent observation ages, restart unknown, no late rebinding | `SelectorExport.swift`; `SelectorExportStore.swift`; `SelectorExportPublisher.swift`; controller/runtime injection | `SelectorExportTests`; `SelectorExportPublisherTests`; controller/data-service tests; TS cross-language contracts |
| Snapshot freshness, replay/regression/duplicate rejection | `src/shared/snapshot-reader.ts` | `contracts.test.ts`; stale publisher and recreated-ID built-package cases |
| One coordinator, FIFO/coalescing, no stale activation after pause/unload | `src/plugin/coordinator.ts`; `ownership.ts`; `index.ts` | 50-trigger unit and built-package cases; resolve/activation barriers; same-location refcounts; mixed versions; real second-process port collision |
| Competitor/version guard and activation readback | `native-adapter.ts`; coordinator guards | Native missing-ID proof; thrown/missing-readback tests; competitor in either location; reload guard |
| Actual primary-request attribution; auxiliary isolation; header coherence | `request-observer.ts`; `transport-hooks.ts`; `hooks.ts` | Late A/two-session failures; title/generate concurrency; four delayed HTTP/WS header cases; socket replacement/full-context continuation |
| Durable cooldown, bounded retry chains, native retry budget | `src/policy/limit-failure.ts`; `state-store.ts`; coordinator retry queue | `failures.test.ts`; `state-store.test.ts`; persisted-before-activation tests; restart/recreated-ID recovery; one tool effect and one prompt across quota retry |
| Native OAuth refresh ownership | `native-adapter.ts` only delegates native resolve | Controlled native single-flight refresh across locations, saved rotated pair, pause and unload while refresh is delayed |
| Acknowledged Swift maintenance and concurrent-token recovery | `SelectorControlClient.swift`; auth/check/repair/sync services | Lost begin response, epoch restart, canceled admission, held maintenance and native-appearance-before-refresh tests |
| Private authenticated controls, sanitized service status, no optimistic UI | `control-server.ts`; `src/service/`; `src/shared/status.ts`; `src/panel/control.ts` | Bearer/epoch/origin/body/descriptor tests; pending/lost-ack panel tests; nullable-history regression; built service crash/uninstall |
| Normal packaging and lifecycle | Build/verifier scripts, manifest and SDK panel | Host install/disable/enable/remove in isolated native instances; eight-file archive inspection; browser checks |

### Findings and test boundaries

- **Fixed:** `publicStatus()` rejected a valid cooldown history entry with `credentialID: null`. The focused service test reproduced the failure before the minimal projection fix; the full suite and built service then passed.
- **Harness corrections:** persisted host service grant scope; lazy location initialization; refresh-transform ordering; and awaited inspection after asynchronous `config.updated` cancellation. These corrections preserve the production boundary rather than replacing the selector under test.
- **Layered activation-unload coverage:** unload during an already-dispatched activation is covered by production coordinator/ownership tests plus the native feasibility harness. The built artifact is not instrumented to pause inside native activation. Built-package unload during delayed native refresh is exercised directly.
- **Native global boundary:** requests resolved before a switch may finish on the old account. Synthetic/tool continuations and auxiliary work do not receive per-request account selection. Only attributed primary retry failures get selector retry handling.
- **No eligible replacement:** leave the current account and native error handling intact. Unknown/stale evidence cannot qualify a replacement. The native retry ceiling remains in force.
- No deferred minor code findings were recorded in this pass. The independent-review and live-acceptance gaps remain explicit below.

## Deferred live acceptance

These actions still require authorization and are not claimed as passed:

- Install through the real Settings UI, confirm paused status, and inspect two real accounts' sanitized expiry/5H/7D mappings.
- Record and intentionally change the native limit-switch/fallback settings; activate a real healthy replacement and send a normal model request.
- Exercise live Pause → native Use → Resume, actual CodexPlusBar quit/reopen and fresh observations, extension lifecycle, and one live rollback restoring the prior account/settings.
- Complete an independent review if requested before integration.

No push, merge, publication, real-account extension installation/switching, or native failover-settings change was performed. Preserve this branch/worktree and local evidence for the authorized next step.

## Rulings carried from the implementation ledger

These are the recorded decisions and their trade-offs, in order. They distinguish intentional choices from accidental omissions.

1. Execute the approved design without reopening brainstorming. Cost if wrong: the user must revise scope during implementation.
2. Keep Learnings and task notes in the feature worktree despite the absolute main-checkout link. Cost: those notes reach main only on integration.
3. Use targeted source inspection without a graph rebuild or global tooling installation. Cost: relationship discovery relies on checking direct call sites.
4. Commit the initial blocked compatibility checkpoint honestly. Cost: the next continuation must resume Task 1 rather than assuming completion.
5. Keep early FIFO/listener/fixture OAuth orchestration in tests until the full coordinator exists. Cost: final built-package tests must expose any mismatch.
6. Delay the real provider's derived header using supported transforms instead of modifying the runtime scheduler. Cost: new runtime versions still need qualification.
7. Exercise host installation modules in an isolated child rather than the live Settings UI. Cost: desktop interaction remains unproved until authorized rollout.
8. Keep unmerged catalog evidence beside normalized display items. Cost: equivalent duplicate catalog rows conservatively exclude expiry.
9. Retain failed-refresh entitlement with its original timestamp; distinguish it from explicit unknown. Cost: the publisher must preserve that distinction.
10. Default controller publisher injection to nil; inject it explicitly in AppRuntime. Cost: any alternate runtime must also inject it.
11. Generate the cross-language export with Swift tests. Cost: clean-checkout TS contracts require the documented Swift-test prerequisite.
12. Retain the original coherence wrapper around the typed implementation. Cost: a small compatibility wrapper remains.
13. Evict the oldest attempt at the 10,000-record bound. Cost: extreme concurrency can fall back to native retry instead of selector override.
14. Check the competitor in every attached location. Cost: another location/provider's configured failover can conservatively block Auto.
15. Keep active maintenance receipts in the bounded 256-entry cache. Cost: saturated maintenance clients must finish holds before adding more operations.
16. Exclude failed native-resolution candidates within the same two-recomputation budget. Cost: three failures defer further candidates until another trigger.
17. Defer sync deletion for all live selector states, including paused, and unknown states. Cost: background removal waits for unload rather than Pause.
18. Durably retain consumed refresh results but refuse live installation after an ownership change. Cost: installation needs an explicit retry.
19. Honor the user's 12ui waiver and use pinned native SDK controls/theme. Cost: visual confidence comes from browser checks rather than generated design alignment.
20. Keep requests bounded at 64 KiB and allow status responses up to 1 MiB. Cost: clients can retain up to 1 MiB of validated local status.
21. Finish authorized isolated acceptance while deferring real rollout. Cost: release readiness still depends on the real Settings/account/settings/rollback smoke test.
22. Perform and label self-review because the user has not chosen subagents. Cost: author blind spots remain; this is not independent review.
23. Retain layered dispatched-activation unload coverage instead of injecting a pause inside the built artifact. Cost: that exact built-artifact timing is not separately demonstrated.
24. Preserve the local ledger/logs while live acceptance remains pending. Cost: local evidence uses disk space until final rollout/integration.
