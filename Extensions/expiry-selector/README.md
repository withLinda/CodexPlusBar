# CodexPlusBar expiry selector

**Compatibility probe only. Not ready to install.**

This folder belongs to the approved expiry-aware selector implementation. Work stopped at
Task 1's required browser identity evidence gate. The Swift publisher and account-maintenance
coordination will live under the repository's `Sources/` after that gate passes.

See [runtime-compatibility.md](docs/runtime-compatibility.md) for the six executed native
tests, the precise blocker, and all untested requirements.

## Development

```bash
npm --prefix Extensions/expiry-selector ci --ignore-scripts
npm --prefix Extensions/expiry-selector run typecheck
npm --prefix Extensions/expiry-selector run test:runtime
```

The runtime command builds a **test-only** plugin and launches the installed OpenCode 2.2.6
binary in private temporary directories with fake credentials and loopback-only networking.
It deliberately exits nonzero until the complete feasibility gate is satisfied. `build`
currently builds only this probe; `verify:package` rejects it as non-installable.

No production Auto selection, service, panel, export, or maintenance client exists yet.
The probe is never installed into the user's OpenChamber. It cleans up its child process
and temporary state; no live rollback is required.
