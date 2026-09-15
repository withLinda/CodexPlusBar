# Compact Everforest redesign — 2026-09-15

## Surface and direction

macOS menu-bar utility and desktop profile manager; extend the existing six-preset Everforest system.

Three directions considered:
- **Editorial:** generous title and credential cards; rejected because usage falls below the fold.
- **Dense table:** maximum comparison density; rejected because reset times, identity, and quick actions compete in narrow columns.
- **Quiet instrument (chosen):** compact profile list, paired capacity readout, one action cluster, and disclosed editing/setup.

## Composition contract

- Main job: find an account with available capacity and open it.
- Reading order: profile identity → remaining capacity and resets → open/refresh → optional editing and connections.
- Manager: 1000 × 680 default, 900 × 600 minimum; 288-point sidebar, flexible detail area, independent vertical scrolling; empty setup is 640 × 240 and grows when a profile is added.
- Popover content: 440 × 560, explicit content width, 16-point internal edge; native popover chrome surrounds it and scrolling supports many profiles.
- Four semantic text roles: 20-point title, 13-point body/semibold labels, 12-point support, capacity values at 28 points expanded / 16 points compact; menu text retains its user zoom.
- Spacing: 4 related labels, 8 controls/rows, 12 group internals, 16 sections/window edge, 24 only for a major reading break.
- Shared anchors: row identity leading edge; equal 5H/7D lanes; reset baseline; trailing action cluster; field leading/trailing edges.
- Compact rows remove nested metric boxes; tags and expiry share the final line when they fit, with a stacked fallback for larger text.
- The signature detail is a precise paired remaining-capacity readout with quiet proportional bars, not decoration.
- Primary orange plate: one intrinsic Save button only when editing, or Add profile in an empty state.
- Blue: navigation/search/reveal; neutral: ordinary selection; status colors always accompanied by text/symbols.
- Boundary hierarchy: native window edge, one quiet content grouping, no nested metric outlines; controls have matte fill, focus has a separate strong ring.
- Optional profile fields and connection setup use disclosure; usage and frequent actions remain in front.
- Editor drafts remain owned by the existing view; no root identity replacement on theme changes or resize; native text editor owns internal scrolling, detail ScrollView owns section scrolling.
- Golden ratio is a **conditional heuristic**, not an Apple rule: primary detail uses roughly two-thirds of usable width, clamped to preserve readable profile names; peer usage windows stay equal.

## Accessibility gates

- Apple HIG: 13-point normal macOS text, 28-point normal controls, 20-point absolute minimum; native menus/buttons, labels for icon-only actions.
- WCAG: raw text contrast ≥ 4.5:1 (prefer 5:1 for dense text); meaningful non-text cues ≥ 3:1.
- Additional product check: D50 CIELAB ΔL* ≥ 40 for required text, independently of WCAG.
- Matte content; title-bar material only, with solid Reduce Transparency/Increase Contrast fallback; no decorative motion.
- Verify normal/minimum windows, all six palettes, long labels, missing usage, empty/search states, and editing after resize/theme change.

## Sources

- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) — platform sizes, contrast, keyboard access, cognitive simplicity.
- [Apple HIG: The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras) — quick access, rich-content exception, alternative entry points.
- HIG MCP material guardrails — navigation-only glass and solid accessibility fallback; numeric blur budgets are community heuristics, not Apple requirements.
- Local skills: swiftui-design-skill, everforest-ui-rules (WCAG/D50 ΔL* recipes), style-guide, swiftui-menubar-design, golden-ratio-layout, swiftui-expert-skill.

## Verified result

Baseline inspected from the running native app: credential fields preceded usage, a detached six-button action card wasted width, and repeated nested outlines dominated the list.

- **Layout:** default 1000 × 680 and minimum 900 × 600 rendered natively; popover content 440 × 560; larger menu text, long labels, missing weekly usage, login repair, empty setup, and search states inspected.
- **Grid:** five native Accessibility profile-row frames measured at the same X and 288-point width, each 106 points high, with 6-point gaps; leading/trailing drift **0 points**.
- **Reading order:** usage is visible immediately; details scroll into view on expansion; reordering and removal are in More; one labeled Settings doorway remains in the popover.
- **Text input:** short and 24-line notes accepted new text after resizing and in-place dark/light changes; native focus remained active and the final line/caret was visible at 900 × 600.
- **Interaction:** Command-F search narrowed the sidebar and selected the matching Claude profile; no-match recovery remained visible; Command-N expanded empty setup into a 900 × 600 editing window; the running app's popover opened the real Settings window.
- **Theme transitions:** fixed stale leaf colors without resetting view identity; matte buttons, fields, metrics, and tags update with the theme.
- **Build:** strict Xcode build passed, including warnings-as-errors and complete concurrency checking; the updated development app was launched.
- **Tests:** 289 tests in 36 suites passed; coverage includes all six theme presets, control idle/hover/pressed/disabled paint, meaningful field and checkbox boundaries, and collapsed editor containment.

### Rendered color audit

Original native PNGs carry a **Display ICC profile**; the Everforest auditor converted them to **sRGB** before testing separate glyph-core and flat-fill samples.

| Measured evidence | Result |
| --- | --- |
| 22 text pairs across six palettes plus dark/light editors | All pass |
| Lowest text WCAG ratio | **5.398703:1** |
| Lowest text D50 ΔL* | **52.409142** |
| Two meaningful field-boundary pairs | Both pass |
| Lowest boundary WCAG ratio | **3.067416:1** |

The raw values are checked against WCAG 4.5:1 for text, 3:1 for meaningful non-text, and the separate product ΔL* ≥ 40 text gate. Decorative section edges are deliberately quieter. The screenshot manifest covers rendered idle pairs; the theme tests cover additional control states. The title-bar material has a solid Reduce Transparency / Increase Contrast fallback.

Evidence: [screenshots](compact-20260915/), [sample coordinates](compact-20260915/contrast-manifest.json), [audit results](compact-20260915/contrast-results.json).

### Design review (self-assessment)

| Dimension | Score | Evidence |
| --- | --- | --- |
| Coherent direction | 9/10 | Matte Everforest, one usage-first task |
| Hierarchy | 9/10 | Capacity first, credentials disclosed, quiet utilities |
| Craft | 8/10 | Shared row anchors, compact native controls, measured contrast |
| Function | 8/10 | Search, sign-in, settings, and resize-then-type exercised |
| Distinctiveness | 7/10 | Paired capacity readout, restrained Everforest identity |

## Reproduce the checks

### Completion audit: remaining utility surfaces

The second native pass found three gaps beyond the primary dashboard: Email Tools still used faint used rows and tiny hover-dependent checkboxes; its session rows nested actions inside a button; Phone summary spent enough height on repeated icons and summary copy to hide the no-number group for just six profiles. The follow-up applies the same compact system to these surfaces, preserves full-strength text, uses native checkbox state and native removal confirmation, aligns expiry in a stable trailing column, and verifies import and OS accessibility states separately.

Platform grounding: [Apple HIG — Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) recommends succinct rows, persistent selection feedback, and preserving recognizable text at narrow widths.

### Utility verification results

- **Email Tools:** 900 × 620 default; 760 × 520 minimum; empty setup 640 × 240. Selected session, unused count, and address list are immediately visible. Seven rows fit the minimum window compared with five at the previous larger 780 × 560 minimum.
- **Row geometry:** eleven native Accessibility address-row frames measured at the same X and 488-point width, each 37 points high, with 4-point gaps; anchor drift **0 points**. Three phone rows share a 540-point width and 36-point height with 4-point gaps.
- **Used state:** readable muted text with strikethrough plus a checkbox. No whole-row dimming or hover-dependent checkbox visibility. Direct copy remains available for used addresses; Copy unused excludes them.
- **Measured checkbox correction:** the initial native tint produced a pale check and an almost invisible off-state. A reusable matte `ToggleStyle` now draws a contrasted boundary and dark on-accent mark, while exposing a native `AXCheckBox` via accessibility representation. AXPress and real Tab/Space activation both passed; a visible focus ring was captured.
- **Email interaction:** fixture automation verified checkbox state, copy contents, used-address exclusion, search, generation, and typing after resize and appearance changes. The preview preserves and restores every clipboard data type during this check.
- **Removal:** a native named alert supports Cancel and Remove; cancel preserved the fixture session and removal selected a surviving session. Normal pointer menu behavior was checked independently of Accessibility tree traversal.
- **Phone summary:** all three categories for the six-profile fixture fit the 900 × 600 window. Expiry values share a trailing lane, in-place appearance changes redraw correctly, and choosing a phone row opens its matching profile.
- **Import:** validated empty, invalid, and valid synthetic input; four invalid rows retained text, focus, and a visible caret through validation growth and an appearance change; valid input enabled Import and closed the sheet. Corrected stale error text after switching appearance.
- **Real OS accessibility:** Reduce Transparency and Increase Contrast were enabled separately through System Settings and confirmed via `NSWorkspace`. Captures show the solid title bar and stronger control boundaries. Reduce Motion was already enabled during these checks. Original settings were restored: transparency reduction off, increased contrast off, reduced motion on, keyboard navigation off.
- **Additional ICC-aware audit:** 36 rendered utility pairs passed across six presets: 24 text pairs at **≥ 4.825318:1** and **ΔL* ≥ 47.781268**, plus 12 checkbox pairs at **≥ 3.340079:1**. The text ΔL* requirement does not apply to checkbox graphics. See [utility sample manifest](compact-20260915/utility-contrast-manifest.json) and [results](compact-20260915/utility-contrast-results.json).

### Completion matrix

| Requested outcome | Current evidence |
| --- | --- |
| Research-led SwiftUI redesign using requested skills and HIG MCP | Three directions, two validated composition contracts, Apple accessibility/menu/list guidance, Everforest contrast recipes |
| Compact and effective front surfaces | Dashboard, menu panel, Email Tools, phone summary, settings, import and empty/sign-in states rendered natively |
| Minimal, low-distraction hierarchy | Capacity first; optional fields/setup disclosed; one intrinsic forward action; no repeated hero blocks or nested metric boxes |
| Sizes and golden-ratio consideration | Measured minimum/default windows, stable rows and anchors; roughly two-thirds primary work area with readable clamped sidebar; no forced ratio for peer metrics |
| WCAG and ΔL* | 60 ICC-managed rendered pairs across the two audit manifests; source token tests cover six presets and interaction paint |
| Keyboard, state, accessibility | Search and editor typing exercised; checkbox Tab/Space and AXPress; real Reduce Transparency/Increase Contrast; focus and clipboard preservation |
| Technical quality | Strict build and 289 passing tests; reusable controls, explicit theme dependencies, isolated native QA host, documented regressions |

The evidence is from native macOS 26 execution and a macOS 14 deployment build; the older title-bar fallback is availability-gated. Captured native alerts and system Settings controls retain platform paint rather than being reimplemented for branding.

### Missing-data appearance regression

The final live-theme audit exposed a real edge case: a profile with no expiry kept a pale **Expiry unavailable** label after changing Dark to Light, even though profiles with expiry dates refreshed correctly. The fallback label now resolves its text from the theme environment; tag fills and OTP value paint use the same explicit preset path.

A reproducible native round trip compares four glyph-and-background regions (selected missing expiry, unselected missing expiry, unavailable weekly reset, and capacity) against fresh launches. **All eight comparisons match exactly, with zero sRGB-channel difference** after ICC conversion. See [transition evidence](compact-20260915/theme-transition-light.png) and [comparison results](compact-20260915/theme-transition-results.json).

```sh
make test AGENT_NAME=design
make build AGENT_NAME=design
bash scripts/render_design.sh --build --output /tmp/manager.png
bash scripts/render_design.sh --compact --light --output /tmp/compact.png
bash scripts/render_design.sh --panel --large-text --output /tmp/panel.png
bash scripts/render_design.sh --details
# In another terminal, with the isolated preview open:
osascript scripts/inspect_design.applescript
# Email workflow, in a separate preview launch:
bash scripts/render_design.sh --email-tools --compact
# Enable macOS Keyboard navigation for this Tab/Space check, then restore it:
osascript scripts/inspect_email_tools.applescript
# Missing metadata must redraw even when its presentation data is unchanged:
bash scripts/render_design.sh --missing-expiry --cycle-theme --output /tmp/theme.png
bash scripts/render_design.sh --missing-expiry --light --output /tmp/theme-fresh-light.png
python3 scripts/verify_theme_transition.py /tmp/theme.png /tmp/theme-fresh-light.png
```

Use the Everforest skill's `audit_screenshot_color.py --manifest docs/design/compact-20260915/contrast-manifest.json` to reproduce the ICC-aware report, and the style-guide skill's `validate_visual_contract.py docs/design/compact-visual-contract.json --phase final` for the composition gate.
