# Expiry selector compatibility gate

Updated: 2026-11-09. **Built extension passes isolated acceptance. Live rollout remains pending authorization.**

## Built-package acceptance (2026-11-09)

Final verification: 168 TypeScript tests in 13 files passed, with zero skips.
The dedicated runtime gate passed 43 cases in three files, including the 18
built-package cases below; these are a subset of the 168, not additional tests.
Swift reported 568 tests in 62 suites with `TEST SUCCEEDED`; ten opt-in checks
were skipped. Typecheck, distribution build, eight-file package verification,
and the macOS build passed. See [the acceptance record](acceptance-2026-11-09.md)
for the skipped checks, archive checksum, review method, and deferred live work.

The actual eight-file `dist/` extension is delivered by the installed host's
installer/catalog/managed configuration into two isolated native locations.
All account identities and provider responses are synthetic; HOME/XDG are private
and outbound traffic is restricted to loopback by the OS. The fixed-port tests
validate the descriptor PID against their own isolated backend before sending controls.

`package.integration.test.ts` executes 18 built-package cases:

- 17-day subscription preferred to 30-day subscription; positive 5H and applicable
  7D evidence required; exhausted windows excluded and fresh positive evidence recovers.
- Tool → quota failure → native B retry: one tool effect, one prompt, same model/context.
- Cooldown survives a real OS process restart and a deleted/recreated credential ID;
  fresh identity binding and positive post-reset evidence are required.
- Stale publisher leaves native requests working on the current account.
- HTTP/WS token-account agreement, socket replacement with full context, and four
  delayed native-header-publication cases (both header casings, HTTP fallback and WS).
- Synthetic wake uses native selection without injecting user prompt admission.
- 50 simultaneous prompts across two locations converge with one activation.
- Two late A failures plus a simultaneous title request preserve B and cool down A only.
- Native user interruption does not rotate or exhaust an account.
- Native delayed refresh is single-flight across two locations; Pause waits for it;
  host disable during refresh drains the owner without stale activation.
- Fixed-port collision with a second built-package OS process blocks that owner.
- Authenticated built service health/status, service crash independence, host uninstall
  draining hooks/listener, and a normal native request after synthetic rollback.

Test-only helpers precede the selector for synthetic OAuth refresh callbacks and
follow it for transport redirection. No selector hooks/coordinator are wrapped or
replaced. Native integration contexts retain the transforms present at their creation,
so registering the refresh helper afterward does not intercept the selector's resolver.
The package verifier excludes every helper from the distribution.

Test boundary: unload **during an already-dispatched activation** is covered by the
production coordinator/ownership barrier tests and the native feasibility harness,
not an injected pause inside the built artifact's native activation call. The live
Settings UI, real account mapping/switching, real CodexPlusBar restart freshness,
native settings restoration, and live rollback are deferred until explicitly authorized.
The earlier authorized read-only identity evidence remains valid; it was not repeated.

Built-package testing found and fixed the service projection rejecting quota history
with `credentialID: null`. A focused service regression failed before the correction.
The panel countdown was browser-checked at 16d 6h, 17d, 30d and expired, at 360px width.

The historical feasibility evidence below remains the record of the initial gate.

## Completed gate (supersedes the checkpoint below)

`npm --prefix Extensions/expiry-selector run test:runtime` exited 0 with **21 tests,
zero skips**: 18 local HTTP model requests and 4 WebSocket connections/exchanges.
Typecheck passed. Swift's final non-opt-in run passed **525 tests / 58 suites** with
`TEST SUCCEEDED`; the live identity test was intentionally skipped in that run,
after the separately authorized two-profile live run described below.

Additional runtime cases beyond the original six:

- Native refresh: two actual location resolvers overlap on one expired fixture
  OAuth connection. Exactly one controlled native refresh callback runs; both
  callers receive the rotated pair and the public stored inventory retains it.
- Tool continuation/retry: A tool response → A quota failure → B retry. Three model
  requests retain `gpt-5.7`, one existing tool result, one tool execution and one
  admitted prompt. Synthetic wake bypasses prompt admission and uses global A.
- Auxiliary attribution: generate B while primary A awaits failure does not exhaust
  B; a delayed title A arriving after primary retry B does not replace B's record.
- Native activation/reload race: a supported test-only provider transform holds
  publication of the account-header projection while native activation/reload
  proceeds. A transport barrier observes the resolved B-token/A-header pair.
  Both header casings pass on HTTP fallback and WS. Temporarily removing the
  production repair made **all four cases fail**; restoring it passed the full suite.
  This controls publication of derived state, not the runtime's internal scheduler.
- A shared test-only FIFO runs real native calls across locations. Maintenance
  acknowledges only after the dispatched activation result settles, rejects resume
  during the hold, and remains paused after release.
- A second real OpenCode process cannot acquire the same loopback listener, and its
  prompt cannot switch A to B. Last-location unload retains ownership until an
  outstanding activation result settles; re-enable creates a new epoch.
- A fixture plugin with the exact competing ID is detected from native inventory
  after configuration reload and blocks activation until removed.
- Installed OpenChamber host lifecycle code installs/grants/disables/enables/removes
  the packaged fixture through a private extension store and its managed config.
  Both explicit locations share an owner; the host may also load its root location.
  Disable/uninstall remove the plugin from both and release the listener. This is
  the real installed host's service-layer lifecycle, not desktop Settings UI QA.

The host test extracts a **read-only copy** of the installed ASAR into ignored
`.runtime/host`, then runs its installer/catalog/managed-config modules in a child
with temporary HOME/XDG and loopback-only egress. ASAR SHA256:
`c4ef6a1bdd7fef0c2a388223441cc7541aae5a377cff33443d6b273e05449589`.
No installed bundle or live extension store is changed.

The queue, private fixture control server, fake OAuth method, tool, lifecycle host
driver, and redirector remain under `tests/` only. They establish feasibility, not
production policy, durable cooldown, control authentication, or restart safety.
Tasks 2–9 must implement and rerun the production contract; actual desktop rollout
and real-account switching still require separate authorization.

## Environment

- Repository baseline: `e28a073dfaff17fde584bcf6063d5a90626ce7f5`.
- Branch: `feature/expiry-selector`, isolated CodexPlusBar worktree.
- Installed OpenChamber: `2.7.0`.
- Bundled binary: `/Applications/OpenChamber.app/Contents/Resources/opencode-cli/opencode`.
- Binary version: `opencode v2.2.6`.
- SHA256: `ffab8fca807e87adc959b7fc3e7e9a867439dd3b6f623a2c6aeb3860f41faa45`.
- `serve --help` verified `--hostname` and `--port`.
- Node `25.8.2`, npm `11.11.1`; exact dependencies and lockfile committed.
- Published SDK versions verified: `@openchamber/sdk@2.7.0`, `@opencode/plugin@2.2.6`.

## Browser evidence check: resolved with user authorization

The user authorized the local evidence probe. `authorizedBrowserIdentityEvidence` ran
inside the Swift test host with the app's signer/session/catalog decoder, at most two
active profiles, GET requests only, an ephemeral URLSession, redirects/proxies/cookie
storage disabled, and no native credential calls. Both profiles independently showed:

- `session.account.id` and `claims.auth.chatgpt_account_id` match the saved native account.
- `session.user.id`, `claims.auth.chatgpt_user_id`, and `claims.auth.user_id` match the saved native user.
- `claims.sub` is a different identity; never use it as a fallback.
- Exactly one normalized catalog entry matches the canonical account.
- Explicit catalog accessibility, deactivation, subscription-active and expiry fields exist.

The report contains only fixed-field shapes and agreement labels. The shared fixture
`Tests/Fixtures/ExpirySelector/browser-identity-evidence-v1.json` recreates those observed
relationships with fake values; it contains no token, cookie, email, real identity or label.
The authorized run completed **524 tests / 58 suites**, including the live evidence check,
with `TEST SUCCEEDED`. The preceding non-opt-in run skipped the live check and separately
passed both sanitizer tests. All raw session data remained in memory.

### Historical blocker (now resolved)

At the earlier checkpoint, browser-to-native identity proof was unavailable.
Existing `Tests/AuthSessionServiceTests.swift` session fixtures contain an account ID
and opaque `token-alpha`/`token-bravo` placeholders. They contain neither an authenticated
session user ID nor usable token claims. `AuthSessionService` currently decodes only
accessToken, account, expiry, and locale. The catalog fixture's `account_owner_id` and
`account_user_id` describe accounts; they are not independent proof of the authenticated
browser user's identity. Native OAuth tests do have `chatgpt_user_id`, but manufacturing
the same field in a browser fixture would not establish the live browser contract.

Design §11.9 requires representative browser/session/catalog evidence before Task 2.
At that checkpoint no live browser evidence had been read. The later authorized
probe resolved the gap without an identity fallback to email or saved profile data.

The original next step was to supply a provenance-reviewed sanitized browser session/token-claim and
catalog fixture, or explicitly authorize a narrowly scoped read-only local evidence probe.
That probe must compare browser account+user to native account+user locally and output
only fake-value shapes, field names, and agreement booleans/hashes. It must not export
tokens/cookies, switch accounts, refresh native credentials, or change settings.
The approved probe supplies that evidence. The remaining runtime proofs still must pass.

## Historical six-test checkpoint

Six tests ran against the built probe loaded by the actual bundled binary:

1. `promptSwitch.firstRequest.identity == B`: first HTTP request is B/B after prompt activation;
   observed RED (A) before adding the minimal native activation seam, then GREEN (B).
2. `two locations share one process-global owner`: both location instances return the same
   Symbol-backed epoch and a count of two. This is not yet a FIFO/refcount lifecycle proof.
3. `missing-ID activation is detected by unchanged native readback`: missing ID activation
   fulfills, but active readback stays A.
4. `raced token B/header A remains coherent on HTTP and WS fallback`: injected stale header
   first reproduced B-token/A-header (RED); the production coherence seam makes it B/B
   (GREEN). One actual HTTP request follows the rejected WS handshake.
5. `retrySwitch.nextRequest.identity == B; late A failure exhausts only A`: deferred local
   quota response is released after location two selects B. Exactly two HTTP requests,
   A then B, and only A is attributed as exhausted. Test retry orchestration is a probe,
   not the production cooldown/selection coordinator.
6. `changed WS account opens a new connection with full context and coherent headers`:
   exactly two local sockets, A/A then B/B; second exchange has no previous-response ID
   and carries more input items than the first, demonstrating full-context replay after
   socket replacement. No tools are present in this fixture.

Aggregate actual transport count for this subset: **4 HTTP model requests, 2 WS
connections/exchanges**, plus rejected WS upgrade attempts used to exercise fallback.
No provider calls leave the machine: macOS Seatbelt denies non-loopback outbound traffic
for the child and descendants. This is OS-enforced exclusion, not a packet-capture claim.

The machine-readable `compatibility-gate.json` now records all ten completed proofs.
`test:runtime` still exits nonzero if any proof becomes partial, blocked, or not run.

## Isolation and reproducibility

```bash
npm --prefix Extensions/expiry-selector ci --ignore-scripts
npm --prefix Extensions/expiry-selector run typecheck
npm --prefix Extensions/expiry-selector run test:runtime
```

Each run creates private temporary HOME and XDG directories and two locations beneath
their own configuration root, checks `/api/info` PID against the exact spawned child,
seeds fake A/B credentials through public APIs, and removes its temporary storage after
terminating only that child. Environment inheritance is whitelisted. A final test-only
transport interceptor redirects verified fixture requests to loopback after the production
observer sees Codex-shaped URLs. No production configuration or database is opened.

Task 1's build creates `.runtime/probe-plugin.js`; it is not `dist/` and must not be installed.
`verify:package` intentionally rejects this non-distributable fixture state. Task 8
will produce the installable selector, and Task 9 will repeat the gate on that build.

## Historical checkpoint verification

- `npm --prefix Extensions/expiry-selector run typecheck`: passed.
- `npm --prefix Extensions/expiry-selector run build`: passed (test probe only).
- `npm --prefix Extensions/expiry-selector test`: 6 tests passed, zero skips.
- `npm --prefix Extensions/expiry-selector run test:runtime`: six tests passed, then
  exited 1 with the incomplete compatibility checklist, as required.
- `npm --prefix Extensions/expiry-selector run verify:package`: exited 1, explicitly
  refusing to treat the test probe as an installable extension.
- Baseline `make test AGENT_NAME=expiry-selector`: **521 tests / 57 suites passed**;
  Xcode exited normally with `TEST SUCCEEDED`.
- No Swift implementation files have changed; Tasks 2–9 were not started.
- No installed application, live account selection, native failover setting, or global
  OpenCode configuration was changed. No rollback of live account state is needed.

## Execution decisions

- Reused the already-approved design instead of reopening brainstorming. Cost if the
  approval is outdated: revise the scope before proceeding past this gate.
- Kept new Learnings and progress notes in the isolated worktree. Cost: main receives
  those notes only when this branch is integrated.
- Used targeted source inspection instead of rebuilding a graph or installing global
  exploration tooling. Cost: later Swift work still requires direct call-site review.
- Saved this blocked milestone as a checkpoint, not a Task 1 completion commit. Cost:
  subsequent work must finish the recorded proof checklist before feature work.

## Harness lessons

- Seatbelt remote IP filters use `localhost:*`, not literal `127.0.0.1:*`.
- Provider `settings.encoding` accepts `none`, not `identity`; invalid config can drop a provider.
- Package a local plugin directory with `package.json` and `exports`; a bare file in the
  `plugins` config was not loaded by this runtime.
- HTTP session creation requires the explicit `location` body to exercise the intended
  location; the directory header alone used the server root and loaded a third location.
- Plugin readiness is checked by bounded inventory polling; a cold initial list can be empty.
