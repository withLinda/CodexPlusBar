# AGENTS.md

## Onboarding
- Use simple English unless a specialized technical term is necessary.
- Read [Learnings.md](/Users/linda/Documents/DEV/CodexPlusBar/Learnings.md) before debugging, tool-heavy work, networking changes, or test repair.
- After any problem or bug that takes extra effort to solve, append a short dated note to [Learnings.md](/Users/linda/Documents/DEV/CodexPlusBar/Learnings.md) with the trap, the fix, and how to avoid it next time.
- Append new knowledge instead of rewriting history. If an older note needs correction, add a newer note that replaces it in practice.

## Releases
- Every GitHub release must include `CodexPlusBar.dmg`, a fresh `expiry-selector.zip` build from `Extensions/expiry-selector`, and `SHA256SUMS` covering both.
- Use `make cloud-dmg` or `make release-assets` to prepare all assets, then `make publish-release` to verify, upload and publish them together. See `docs/releases/cloudkit-dmg-runbook.md`. Never publish only the DMG or reuse an older extension ZIP.
- iCloud Sync stays opt-in on each Mac, including releases from `main`.
