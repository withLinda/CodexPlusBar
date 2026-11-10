# Account Priority for OpenChamber

Selects the earliest verified OpenAI subscription expiry among identity-matched accounts with usable five-hour and applicable seven-day quota. Unknown, stale, exhausted, expired, or conflicting evidence cannot qualify an automatic replacement.

Expiry means the subscription countdown shown in CodexPlusBar, such as **Expires in 16d 6h**. A healthy account with 17 days left is preferred over one with 30 days left. The panel shows days/hours remaining; hover for the exact expiry date. OAuth token expiry and quota reset timers do not determine priority.

## Build and verify

Requires Node 22+, npm, and the pinned development dependencies. From this repository:

```sh
npm --prefix Extensions/expiry-selector ci
npm --prefix Extensions/expiry-selector run typecheck
npm --prefix Extensions/expiry-selector run build
npm --prefix Extensions/expiry-selector test
npm --prefix Extensions/expiry-selector run verify:package
```

On a clean checkout, run `make test AGENT_NAME=expiry-selector` first. Swift contract tests generate the ignored cross-language export fixture. Runtime tests require the supported OpenChamber macOS installation and run with synthetic credentials in isolated homes.

The built `dist/` folder is the extension. Do not install the source directory or `.runtime/` probes. Packaging verification must pass before installation.

Every CodexPlusBar release includes [the current extension ZIP](https://github.com/withLinda/CodexPlusBar/releases/latest/download/expiry-selector.zip). Extract it and select its `expiry-selector/` folder when installing. The archive contains only the eight verified distribution files; its `package.json` records the extension version. `SHA256SUMS` in the same release covers both the ZIP and DMG.

`make cloud-dmg` rebuilds and verifies this extension and prepares all three release assets. To prepare assets from an already notarized DMG, run `make release-assets RELEASE_DMG=/path/to/CodexPlusBar.dmg RELEASE_ASSETS=/path/to/new/github`. This installs the locked dependencies and builds from the current source checkout. See the [release runbook](../../docs/releases/cloudkit-dmg-runbook.md#github-release-assets).

The historical acceptance archive was `output/expiry-selector-0.1.0.zip`; `docs/acceptance-2026-11-09.md` records that artifact's checksum and review boundaries.

## Supported boundary

- Verified OpenChamber **2.7.0** and bundled OpenCode **2.2.6** on macOS. Other OpenCode versions block Auto until tested. The manifest's host minimum is not evidence that future versions are compatible.
- Native `chatgpt-browser` and `chatgpt-headless` OAuth connections with matching access-token and account metadata identities. No independent OAuth storage or refresh implementation.
- Native selection is global across locations. Prompt admission and primary retry are guarded; this does not promise per-session account isolation or exact expiry ordering for every synthetic/tool continuation.
- Retries use the account observed on the actual primary HTTP/WS request. Title and other background work never spend another account's quota retry budget. Unrecognized failures retain native retry handling.
- Recheck rereads published observations and native inventory. Refresh CodexPlusBar for new usage/expiry evidence. Publisher heartbeat older than 90 seconds, usage older than 15 minutes, and entitlement older than 24 hours are ineligible.
- If no candidate qualifies, the current native account remains selected and native error handling continues.

## Install and operate (requires user authorization)

1. Record the selected native account and the current OpenChamber native limit-switch/fallback settings.
2. Install the verified `dist/` folder through **Settings → Extensions**. Approve its plugin and local service capabilities. First installation starts paused.
3. Open **Account Priority**. Confirm paused status and the expected identity-linked accounts and observation freshness.
4. Disable competing native limit switching/fallback intentionally. Auto requires the `openchamber-limit-failover` plugin to be absent in every attached location, including when another provider's settings keep it loaded. This extension never changes those settings.
5. Enable Auto only after confirming the mapping. Controls wait for acknowledgement; a timed-out control is unconfirmed, not proof it failed. Retry the same operation's acknowledgement.

Before native **Use**, click **Pause Auto**, wait for acknowledgement, then use the native control. Resume explicitly when ready. CodexPlusBar's manual switch/check/repair operations obtain an acknowledged maintenance hold and leave Auto paused. A hold does not stop OpenCode's own OAuth refreshes or model requests. Background sync defers removals whenever a selector owns selection or cannot be verified.

## Unload and rollback

Pause and wait for acknowledgement, then disable/remove the extension through Settings. Restore the prior native selected account and prior limit-switch/fallback settings using native controls. Verify a normal request. Do not remove credentials or profiles. Re-enable only when requested.

The panel's service is a status/control bridge. Closing it or a service crash does not stop the plugin's coordinator. Disabling/removing the extension unloads its hooks and drains pending native work before releasing its listener. The fixed control port is `127.0.0.1:53971`; a collision blocks Auto rather than choosing another port.

Private files: `~/.codexplusbar-selector/runtime.json` (live epoch/bearer; removed on clean shutdown), `state.json` (paused/Auto preference, cooldowns, bounded redacted history). Both are 0600 inside a 0700 directory. Preferences/history may remain after removal. No OAuth credentials are kept there.

For a crashed maintenance client, Auto stays paused. First confirm all CodexPlusBar maintenance operations have ended, then disable the extension and wait for its listener to close. Back up `state.json` privately; change only `maintenanceRecovery` to `false` and keep `desiredMode` as `paused`, retaining all cooldowns/history and 0600 permissions. Re-enable, inspect paused status, and Resume explicitly. Do not edit a running owner's files or delete cooldown evidence to recover a hold.

Published observations: `~/Library/Application Support/CodexPlusBar/Exports/openchamber-selector-v1.json`. This file contains sanitized identity/account mapping and quota/entitlement evidence, never tokens, cookies, or prompts.

## Acceptance status

The built package has isolated native-runtime acceptance evidence, including host delivery/removal, concurrent prompts, actual-request quota attribution, HTTP/WS coherence, process restart, delayed refresh, and service crash. See `docs/runtime-compatibility.md` for exact coverage and `docs/acceptance-2026-11-09.md` for final checks and self-review. Live installation, live account switching, native settings changes, and live rollback have **not** been authorized or performed for this extension.
