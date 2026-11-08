# Repair both verification

## Scope

One inline action repairs the selected profile's ChatGPT / Codex and OpenChamber sign-ins. It uses separate official browser grants, checks both account and user identity, saves each completed grant privately, and preserves partial progress for retry. An unrelated live selection remains selected.

## Evidence

- Installed helper: `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` supports `initialize`, `account/login/start`, and cancellation. The returned authorization uses OpenAI's issuer, loopback callback, and S256 PKCE.
- `OPENCHAMBER_TEST_SWIFT=1 python3 scripts/test_openchamber_v2_bridge.py`: 519 tests in 57 suites passed in the final uninterrupted run. This includes production native credential replacement for active and inactive accounts, metadata retention, helper start/cancel, restart recovery, event ordering, identity rejection, partial completion, interrupted desktop commits, and backup compatibility.
- `make build CONFIGURATION=Release AGENT_NAME=repair-both`: passed with warnings treated as errors. Developer ID signature verified with `codesign --verify --deep --strict`.
- Native compact previews: progress, partial completion, and success in light/dark. Evidence images are under `build/repair-*.png`.
- `scripts/verify_repair_actions.swift`: native Repair both and Cancel actions passed; both switches, Check sign-ins, and Sync now are disabled during repair. Tab/Space activation passed with the original keyboard-navigation preference restored afterward.

## Boundaries

Automated checks use synthetic credentials and an isolated real OpenCode backend. The official helper is started and cancelled without completing a live user authorization. No real account's OAuth consent or repaired credential installation was exercised by these checks.

The installed helper owns the fixed callback ports. Availability is checked before launch and immediately before starting login; concurrent login started by another app between that check and its bind remains an upstream limitation.

## Review corrections

The independent review identified desktop native rotation adoption, native receipt continuity after another refresh, consumed-token preservation on cancellation, and queued refresh rows left loading. Regressions reproduced all four paths before their fixes. Desktop receipts now distinguish saved-vault completion from live installation and journal installation intent before committing. An interrupted intent is reconciled only against its exact previous/target fingerprints; ambiguous external changes preserve both stores and automatically require a new browser grant. Native adoption records its link to the original browser grant before a subsequent refresh; consumed installed pairs are replaced before cancellation or fallible usage verification. Existing refresh batches drain before browser authorization starts. An encrypted backup roundtrip covers the new desktop receipt files.

## Local artifacts

Previous installed app: `build/local-app-signin-repair-20261108/CodexPlusBar-before-repair.app`.

Installed `/Applications/CodexPlusBar.app`, verified its Developer ID signature, launched it, and confirmed the Repair both control through read-only Accessibility inspection. Installed executable SHA-256 matches the reviewed Release product: `a21dab9fc285add016186b22ad85cdd0eba7212c1afc993fe40c2662c811bff1`.

Integration log: `build/repair-integration.log`; full test log: `build/logs/openchamber-sync/test.log`.

## Live callback handoff correction

The first live use exposed a missing TCP lifecycle case: after desktop authorization completed, the next login's plain bind preflight rejected macOS TIME_WAIT as another active sign-in. No second browser window could open. The preflight now uses SO_REUSEADDR to match the helper listener while continuing to reject actual listeners on either callback port.

`consecutiveLoginsOpenBrowserAfterCompletedCallback` reproduced `.loginBusy` before the fix using actual loopback HTTP traffic and passed afterward. Active listeners on 1455 and 1457 remain blocked without receiving any connection. The installed official helper also started and cancelled twice after local HTTP callback traffic. The final isolated-backend run passed 521 tests in 57 suites; Release build and Developer ID signature passed. Logs: `build/repair-callback-red.log`, `build/repair-callback-green.log`, and `build/repair-callback-release.log`. The previous installed app is retained under `build/local-repair-callback-fix-20261108`.

Review also reproduced Darwin's wildcard-binding exception: loopback-only reuse could miss an active 0.0.0.0 listener. The guard now probes both loopback and wildcard addresses, with active-listener cases covering both ports and both address types. Regression evidence: `build/repair-callback-listener-red.log`.

After that review correction, all 521 tests passed again in 26.317 seconds. Installed the signed corrected build in `/Applications/CodexPlusBar.app`, verified the signature and executable match, and confirmed launch and Repair both visibility through read-only Accessibility inspection.
