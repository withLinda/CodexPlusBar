# OpenChamber 2.7.1 / OpenCode 2.2.7 compatibility

## Failure and correction

The Account Priority extension 0.2.0 accepted only the literal OpenCode version
`2.2.6` in both coordinator guards. Updating OpenChamber to 2.7.1 changes its
bundled OpenCode to 2.2.7 and blocks Auto before candidate selection.

Extension 0.2.1 admits exactly `2.2.6` and `2.2.7` using a shared verified-version
list. Status reports both tested host/runtime versions. Unknown versions remain
blocked, including other patch versions and prereleases.

## Evidence

- Official macOS arm64 OpenChamber 2.7.1 ZIP SHA256:
  `29bfb0f5343e86254b8b1c3b8cfce4ad4cc1ecba385544f5ebe65e96b5d4f1da`.
- Download SHA256 matched the GitHub release asset digest before extraction.
- Bundled `opencode --version`: `opencode v2.2.7`.
- Bundled executable SHA256:
  `139e992c4ce17f35eddf6791218c150bbbe3209310b0b2c46706ed759b44d21f`.
- OpenChamber 2.7.1 ASAR SHA256:
  `9f862203000386816e9a73ec7f3df3716f894b0b746cadbafe51b03a90f0c61c`.
- RED: the coordinator regression on 2.2.7 returned a null preview candidate;
  the same 2.2.6 case passed. After correction, 28 coordinator cases passed,
  including rejection of unknown versions in either attached location.
- Full extension suite on 2.7.1 / 2.2.7: **183 tests in 13 files passed**,
  including all 43 real-runtime cases and 18 built-package acceptance cases.
- Full extension suite on 2.7.0 / 2.2.6: **183 tests in 13 files passed**
  with the same corrected harness. Typecheck and the eight-file package verifier
  passed. The live selector still owned port 53971 with its original PID afterward.

Logs and the downloaded test bundle are retained locally under
`build/compatibility-2.2.7/` (ignored build artifacts).

Transfer artifact: `build/compatibility-2.2.7/expiry-selector-0.2.1.zip`.
All eight ZIP entries were checked byte-for-byte against verified `dist/` files;
both shipping control-port declarations remain 53971. ZIP SHA256:
`fbdd305b0cf148e6bd84a9dfae127d368499666d0714393f3770d6fcf573cc4d`.

## Test boundaries and timing fixes

Each runtime uses private HOME/XDG directories, synthetic credentials, fake
loopback provider traffic and OS-enforced loopback-only outbound networking.
The host installer, grants, managed configuration and removal use the downloaded
host's actual modules and metadata version. Neither installed app was updated.

The live selector occupies port 53971. Tests replace only the generated
`controlPort` declaration in private plugin/service copies with one test port;
the distribution retains 53971 and has no runtime port override. A second
test process intentionally uses that same test port to verify exclusive ownership.
All selection, retry, transport and persistence code is the built distribution.

The first 2.2.7 run exposed tests sending RPCs or reading the descriptor before
plugins became active after reload/restart, plus a recheck racing a late config
event. The harness now waits for the expected active plugin inventory and the
stale-publisher assertion waits for a completed observation. The initial 14
failures included cascading failures from the aborted stale-publisher scenario;
the next run isolated the remaining cold-restart readiness failure. Final full
verification passed after those test-only readiness corrections.

Real-account switching and installation on the user's other Mac still require
the transferred extension. This record proves isolated compatibility, not a
completed installation on that Mac.

## Reproduction

From `Extensions/expiry-selector`, with the desired macOS app bundle available:

```sh
EXPIRY_TEST_OPENCHAMBER_APP=/absolute/path/OpenChamber.app npm run test:runtime
EXPIRY_TEST_OPENCHAMBER_APP=/absolute/path/OpenChamber.app npm test
npm run typecheck
npm run verify:package
```

Run versions sequentially because `.runtime/host` and the built probes are
shared test artifacts. The existing browser-to-native identity proof remains
the authorized evidence recorded in `runtime-compatibility.md`.
