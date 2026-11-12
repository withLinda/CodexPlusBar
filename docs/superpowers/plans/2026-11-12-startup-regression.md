# Startup regression investigation

- [x] Compare 1.6.2 with 1.7.4 and inspect the running app/selector.
- [x] Confirm the user rolled back; current 1.6.2 has a status item and fresh, trusted selector exports.
- [x] Trace the shared regression: AppRuntimeController awaits cloud identity, fetch, saved-session capture and upload before creating its lazy status item or starting profile refresh/selector publishing.
- [x] Reproduce blocked startup with controlled cloud identity/fetch barriers and real local consumers.
- [x] Decouple local readiness from cloud networking while retaining pending catalog/restore protection and shutdown fencing.
- [x] Run targeted startup, cloud coordinator, selector publisher and menu bar checks (106 tests / six suites); initial signed production build verified.
- [x] Record evidence and the prevention rule in Learnings.md.
- [x] Independent review: reproduce and close first-union/native-drain and manual-recovery-action gaps.
- [x] Verify and install the final signed build; confirm menu and live Account Priority after restart.

No full suite is planned. Existing user changes in Learnings.md and untracked files are preserved.
