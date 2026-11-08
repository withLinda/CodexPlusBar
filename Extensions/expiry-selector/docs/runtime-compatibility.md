# Expiry selector compatibility gate

Date: 2026-11-08. **BLOCKED — Task 1 is incomplete. No installable selector.**

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

## Blocking check: `browserIdentity.accountAndUser`

The required browser-to-native identity proof is **unavailable**, not disproved.
Existing `Tests/AuthSessionServiceTests.swift` session fixtures contain an account ID
and opaque `token-alpha`/`token-bravo` placeholders. They contain neither an authenticated
session user ID nor usable token claims. `AuthSessionService` currently decodes only
accessToken, account, expiry, and locale. The catalog fixture's `account_owner_id` and
`account_user_id` describe accounts; they are not independent proof of the authenticated
browser user's identity. Native OAuth tests do have `chatgpt_user_id`, but manufacturing
the same field in a browser fixture would not establish the live browser contract.

Design §11.9 requires representative browser/session/catalog evidence before Task 2.
No real browser session, profile store, saved native credential, cookie, or live sign-in
was read to fill this gap. No identity fallback to email or saved profile data was added.

**To unblock:** supply a provenance-reviewed sanitized browser session/token-claim and
catalog fixture, or explicitly authorize a narrowly scoped read-only local evidence probe.
That probe must compare browser account+user to native account+user locally and output
only fake-value shapes, field names, and agreement booleans/hashes. It must not export
tokens/cookies, switch accounts, refresh native credentials, or change settings.
Then rerun and complete all ten proofs; this gap does not authorize skipping the rest.

## Executed native runtime subset

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

The machine-readable `compatibility-gate.json` maps all ten required proofs to the exact
remaining work. `test:runtime` intentionally exits nonzero while any proof is partial,
blocked, or not run. A passing six-test subset is never the full gate.

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
`verify:package` intentionally rejects this incomplete state. Native extension lifecycle,
tool replay, auxiliary concurrency, single-flight refresh, competitor reload, and maintenance
barrier checks have not passed and are not represented by mocked replacements.

## Other verification

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
