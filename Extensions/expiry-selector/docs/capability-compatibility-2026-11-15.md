# Capability-based upgrade compatibility

## Recurring failure

OpenChamber 2.7.2 bundles OpenCode 2.3.0. Account Priority 0.2.1 allowed only
OpenCode 2.2.6 and 2.2.7, so a version change alone blocked Auto even when the
required APIs still worked. Adding another version would repeat the problem
on the next update.

## Extension 0.3.0

OpenCode versions are no longer an admission rule. Every attached location must
provide the native plugin inventory, session lookup, integration inventory,
active connection, credential resolver and credential activation APIs.

The adapter begins in `hooks-not-ready`. All five hooks must register with
disposable handles: `model.request`, `http.request`,
`experimental.ws.handshake`, `prompt`, and `retry`. The lifecycle subscription
must expose an async iterator. Unexpected termination, including a clean early
end, blocks Auto and invalidates pending selection.

Missing native APIs, unavailable hooks, incomplete setup and a lost lifecycle
subscription have separate status messages. Failed installation cleans partial
registrations while retaining the status/control bridge. Reload the extension
after restoring a missing API or lost subscription. Existing per-operation data
validation, identity checks, quota freshness, maintenance, single ownership,
native refresh, activation readback and competing-switcher checks remain active.

The process-global implementation version is incremented so a new adapter cannot
silently share an old version-pinned coordinator during mixed-version delivery.
The status protocol retains its `supportedVersions` fields for existing clients;
their strings now describe the required contract, and the panel labels them
“Compatibility.”

The development SDK stays pinned for reproducible builds. It is bundled out of
the shipped plugin and is not an installed-runtime version restriction. The host
manifest still requires OpenChamber 2.7.0+ and extension API 1.

Compatible future versions need no allowlist update. Capability checks cannot
prove the behavior of an unreleased runtime; an actual API or hook semantics
change may still need an extension fix. The isolated runtime harness now accepts
any selected bundle and checks its real behavior rather than rejecting its
version before running.

## Evidence

- Installed OpenChamber: **2.7.2**.
- Bundled binary: `opencode v2.3.0`.
- Binary SHA256: `96b929692b143554f17031775a77eb5265e62184bf3f28ae7d4dec5e2c0578b7`.
- Host ASAR SHA256: `87e235b0e4d6c762e60d3a609b5e406c3ffd61b3be9eada584d6dcff3b83f912`.
- RED: 10 coordinator cases failed, including 2.3.0/future-version admission,
  missing capability rejection and capability loss during identity resolution.
- RED: all 17 installation compatibility cases failed against the old behavior,
  including unfinished setup admitting Auto and missing/ended event subscriptions.
- GREEN: 60 focused cases in four files passed; typecheck passed.
- The dedicated native runtime gate passed **43 tests in three files**, including
  built-package delivery/removal, actual switching, retry, refresh, maintenance,
  process restart and HTTP/WS coherence.
- Final full extension suite: **205 tests in 14 files passed**, including those
  43 real-runtime cases; typecheck and the eight-file package verifier passed.

The first full run exposed a timing-dependent setup in the late-quota test
(204 passed, one failed). It manually activated B while Auto still preferred
healthy A, so a `config.updated` selection could legitimately activate A before
the held quota response arrived. The corrected fixture publishes fresh exhausted
A usage, waits for a completed automatic B replacement, then releases A's delayed
response. It verifies one initial replacement, no additional activation during
the late retry, A→B request identities, and a cooldown for A only. Selection policy
was not changed to accommodate the test.

Runtime tests use private HOME/XDG directories, synthetic accounts, fake loopback
provider responses and OS-enforced loopback-only outbound networking. Private
test copies remap the control-port constant; the shipping package retains 53971.
These results do not represent live user-account switching or installation.

```sh
npm --prefix Extensions/expiry-selector run build
npm --prefix Extensions/expiry-selector test
npm --prefix Extensions/expiry-selector run typecheck
npm --prefix Extensions/expiry-selector run verify:package
```

To check a later host without installing it, set
`EXPIRY_TEST_OPENCHAMBER_APP=/absolute/path/OpenChamber.app` for the test command.
Run different host versions sequentially because build/probe artifacts are shared.

## Local installation artifact

- ZIP: `build/compatibility-capabilities-20261115/expiry-selector-0.3.0.zip`.
- Extracted folder: `build/compatibility-capabilities-20261115/expiry-selector/`.
- SHA256: `038d7ea43ff7a5ee65edf525596d8446df92e06682aae28603b09a69309c6e9f`.
- All eight ZIP entries match the verified distribution byte-for-byte. Both
  shipping control-port declarations remain 53971.

Replace the extension through OpenChamber **Settings → Extensions**, selecting
the extracted `expiry-selector` folder. Reload the updated extension and inspect
Account Priority before enabling/resuming Auto. The source change and ZIP are
the local development handoff artifacts. The subsequent
[CodexPlusBar 1.7.8 release](../../../docs/releases/1.7.8.md) rebuilds and ships
the same extension version as `expiry-selector.zip` alongside the DMG.
Installation into the running OpenChamber instance remains a user step.

## Review

Independent read-only review approved packaging with no Critical or Important
findings. Two non-blocking status-display refinements remain: a compatibility
failure stops refreshing the displayed snapshot, and an event-stream failure
during the final Enable Auto persistence await can temporarily clear the displayed
block reason. Per-operation capability checks still prevent selection in both
cases. Live installation/mixed-version delivery and unreleased API semantics were
not certified by the review.
