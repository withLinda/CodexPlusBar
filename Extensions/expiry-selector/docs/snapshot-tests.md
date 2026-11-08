# Snapshot contract tests

Run from the repository root:

```sh
make test AGENT_NAME=expiry-selector
npm --prefix Extensions/expiry-selector test -- tests/contracts.test.ts
```

The Swift test decodes `tests/fixtures/selector-v1.json`, checks semantic equality,
and writes its real encoded output to ignored `.runtime/swift-export.json`.
TypeScript validates both files. Run Swift first on a clean checkout.

The shared fixture includes A/B quota windows and null evidence for C. Table-driven
mutations cover stale/future timestamps, unknown versions, excessive size/count,
out-of-range quota, conflicting identities/bindings, and unexpected fields.

Publisher tests use injected clocks, binding readers and isolated file destinations.
They cover the actual 30-second scheduler, shutdown, overlapping refresh generations,
rebinding, sign-out/removal, failed expiry retention, atomic failure and file modes.
