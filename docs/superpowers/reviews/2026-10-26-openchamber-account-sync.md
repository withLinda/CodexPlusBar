# OpenChamber account sync verification

## Result

- Implemented automatic mirroring, the persistent setting, sync status/Sync now, and direct Remove beside Refresh.
- Launched `build/DerivedData/openchamber-sync/Build/Products/Debug/CodexPlusBar.app` through `make run AGENT_NAME=openchamber-sync`.
- Live inventory: 10 saved Codex profiles, 9 matching OpenAI OAuth logins, zero surplus. The approved mirror removed 18 surplus logins from the initial 27. The active login belongs to the retained set; no active deletion is deferred.
- Native manager status: **9 of 10 profiles linked; 1 need sign-in.** The remaining profile needs device-code login in OpenChamber followed by **Save current sign-in** in CodexPlusBar.

## Evidence

- `OPENCHAMBER_TEST_SWIFT=1 python3 scripts/test_openchamber_v2_bridge.py`: **427 tests in 46 suites passed in 9.251 seconds**, including both production native client/service reconciliation and the existing bridge integration; final run exited normally.
- `make build AGENT_NAME=openchamber-sync`: succeeded with Swift 6 complete concurrency checking and warnings as errors.
- Native accessibility checks at **900×600**, **1000×680**, and **1120×792**, in dark/light: Refresh and Remove fit on one row; one Remove press deletes the disposable profile; Sync now publishes synthetic status.
- Real keyboard Tab/Space reached Remove and deleted the disposable profile; the original macOS keyboard preference was restored.
- Captures: `/private/var/folders/43/wvysbd0n0fs9n2724h44s4br0000gn/T/opencode/sync-compact-dark.png`, `sync-compact-light.png`, and `sync-normal-dark.png`. Geometry/actions were inspected through native accessibility; image pixels were not independently reviewed.
- `git diff --check`: clean. Unrelated pre-existing edits were preserved through selective commits.

## Review

The requested fresh-context reviewer stopped at its usage limit before returning findings. Final review was performed by the implementing agent; it is not independent review.

Five important findings were reproduced with failing tests, fixed, and verified in the final green suite:

1. Recheck account selection after awaited idle lookup before activating a replacement.
2. Validate exactly the expected inventory change after rename/activation/removal; do not accept a concurrent selection into an obsolete removal plan.
3. Keep refreshed OAuth generations recoverable across failed installation, stale native readback, and a new service instance.
4. Reject an email-only manual capture when native inventory contains different account/user identities for that email.
5. Reject malformed OpenAI credential kinds instead of treating them as absent OAuth accounts.

## Rulings made

- Used the approved current checkout and selective staging. Cost if wrong: changes need to be separated later.
- Used complete Swift Testing summaries for earlier post-suite Xcode shutdown timeouts rather than rerunning identical checks through the plan wrapper. Cost if wrong: those wrapper exits are not established; the final run and separate build both completed normally.
- Extracted scheduling into `OpenChamberSyncScheduler`. Cost if wrong: one extra layer of indirection.
- Completed author review after the reviewer usage-limit failure. Cost if wrong: no independent reviewer caught remaining blind spots.
- Allowed OpenCode to select a remaining API key when its active surplus OAuth credential is deleted without a desired replacement. The isolated server demonstrated this native behavior. Cost if wrong: an external selection at that exact boundary is indistinguishable from native fallback.
- Added private consumed-generation replacement records shared by manual auth and synchronization. Cost if wrong: additional private recovery files need maintenance.

## Deferred minor

An intentionally empty desired/remote login list says **OpenChamber synced · 0 profiles** rather than explicitly prompting for an OpenAI sign-in. The count and synchronization state remain accurate.
