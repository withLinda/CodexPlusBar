# Menubar Inline Actions Restoration Design

Date: 2026-04-20
Surface mode: `menu bar`
Status: approved direction, pending final spec review

## Goal

Bring back three fast actions inside the menu bar panel:

- `Copy`
- `Email link`
- `Show on top`

Do this without bringing back the older heavier card layout. The panel should stay calm, readable, and easy to resume after distraction.

## Problem

The current menu bar panel uses a cleaner summary row, but the fast actions moved into the row context menu. That reduced visible clutter, but it also hid common actions behind right click. For this compact utility surface, that is too much memory work.

## Design Direction

Keep the current summary-row structure and restore a small inline action rail inside each menu bar row.

The row stays split into three visual jobs:

1. identity and usage summary
2. quiet secondary actions
3. one clear pinned-state control

The main row body still opens the manager window for that profile.

## Layout

Each menu bar profile row should include:

- profile label
- existing usage summary blocks
- support line
- `Copy` icon button
- `Email link` icon button
- `Show on top` capsule

The row should not go back to the older multi-card composition with a separate top-right status cluster. The current denser summary row stays the base.

## Interaction Rules

### Row tap

- Tapping the main row opens the manager window for that profile.
- Inline controls must not trigger the row tap action.

### Copy

- Copy the profile label to the pasteboard.
- Use a quiet icon treatment so it reads as a secondary action.

### Email link

- Open the stored email link when present.
- If the profile has no email link, keep the button visible but disabled.
- Help text should explain why it is disabled.

### Show on top

- If the row is not pinned, show a warm capsule labeled `Show on top`.
- If the row is already pinned, show a calmer state chip labeled `On top`.
- The pinned chip stays visible so users do not need to remember which profile drives the menu bar title.
- The control remains disabled when already pinned.

### Context menu

Keep the existing context menu actions as a fallback:

- `Show on top` or current-state variant
- `Copy profile label`
- `Open email link` when available
- `Open manager`

## Visual Rules

- Keep the row background and usage summary from the current redesign.
- Do not add extra cards, duplicate badges, or decorative summary chrome.
- `Copy` and `Email link` should use quiet icon buttons that match the current design system.
- `Show on top` is the only action that should carry warm accent emphasis inside the row.
- The pinned state chip should look calmer than the active action chip.
- Keep text sizes within the current compact panel system and do not shrink below the current row typography.

## Accessibility

- All icon-only controls need clear accessibility labels.
- Disabled email action should still expose a stable label and hint/help text.
- Decorative pinned icon treatment, if any, should stay hidden from accessibility.
- The main row and its inline controls must remain separately reachable by assistive technologies.

## State And Data Flow

- Continue to read and write the pinned profile through `MenuBarProfilePreference`.
- Reuse the existing email-link resolution logic on `PlusProfile`.
- Keep the status-item summary behavior unchanged: pinning a profile here should still drive the menu bar title through the existing preference observer path.

## Testing

Follow test-first work.

Add or update tests for:

- menu bar row presentation exposes inline secondary actions in menu bar mode
- pinned menu bar presentation exposes the pinned state chip
- disabled email action path is represented in the menu bar row presentation
- menu bar root view no longer asserts that inline actions are absent

## Out Of Scope

- changing the manager window layout
- changing the status-item title format
- adding hover-only behavior
- adding more per-row actions
- redesigning the panel as a larger mini-app

## Success Check

The panel should feel like a valet tray:

- one obvious primary row target
- visible fast actions for common tasks
- no extra reading burden
- pinned state obvious at a glance
