# Menubar Expiry And Compact Density Design

Date: 2026-04-21
Surface mode: `menu bar`
Status: approved direction, implementation in progress

## Goal

Make each profile row in the menu bar panel easier to scan in one pass.

The row should answer:

- which account this is
- how much `5H` and `7D` usage remains
- when the account entitlement expires
- where the fast actions live

## Problems To Fix

- The `Plus · <short account id>` line adds noise and does not help account choice.
- Expiry is not shown in the menu bar row even though it matters for account choice.
- `Copy`, `Email link`, and `Show on top` are visually separated from the email label.
- The current row height is still heavier than necessary for a compact utility panel.

## Design Direction

Use the existing summary row as the base, but make the menu bar mode denser and more informative.

`platform rule`: keep common actions visible in a compact utility surface.

`research-backed heuristic`: reduce memory work. Do not make the user remember hidden actions or mentally combine data from different places.

The recommended layout is the tight header rail:

- first line: email on the left, fast actions on the right
- second line: `5H` and `7D` usage blocks
- third line: expiry line in the same `Expires in ...` style used by `CodexTeamBar`

## Layout

Each menu bar profile row should include:

- profile email label
- `Copy` icon button
- `Email link` icon button
- `Show on top` capsule
- `5H` usage block
- `7D` usage block
- expiry line

Compactness rules:

- remove the `CodexPlusBar` eyebrow text from the panel header
- keep `Profiles` as the main header title
- tighten row padding and internal spacing
- keep usage blocks readable, but do not give them extra decorative chrome
- keep the content matte; only the pin action should carry warm emphasis

## Expiry Rules

Use the same expiry wording pattern as `CodexTeamBar`, backed by `DisplayFormatter.expiryValue(...)`.

Behavior:

- active entitlement: show `Expires in <duration>`
- expired entitlement: show `Expired`
- missing entitlement date: show `Expiry unavailable`

Color behavior:

- more than 7 days: muted gold
- 3 to 7 days: warm orange
- under 3 days or already expired: warm red

The expiry line replaces the current support line in menu bar rows that already have live usage data.

For rows without live usage data yet:

- keep the current state or error support message
- do not force an expiry line if the row is still in a login or failure state

## Interaction Rules

- Tapping the main content area still opens the manager window for that profile.
- Secondary controls must stay outside the primary tap region.
- `Copy`, `Email link`, and `Show on top` sit beside the email label in the top row.
- Keep the context menu actions as a fallback.

## Data Flow

The menu bar row needs real entitlement expiry, not a local guess.

Source of truth:

- fetch `/backend-api/accounts/check/v4-2023-04-27`
- find the catalog entry that matches the current profile account ID
- read `entitlement.expires_at`

Implementation shape:

- add a small account-catalog service for this repo
- return expiry refresh data together with the existing usage refresh result
- persist the last known expiry on `PlusProfile`
- expose expiry on `PlusProfileSnapshot`
- render the expiry line only in menu bar ready rows

Failure behavior:

- if usage refresh succeeds but catalog refresh fails, keep the row usable
- preserve the last known expiry instead of clearing it on a transient catalog failure
- if catalog refresh succeeds with no expiry, store `nil` explicitly

## Accessibility

- keep icon buttons labeled
- keep the pin capsule text visible
- keep the expiry value readable without relying on color alone
- preserve separate accessibility targets for the row and the inline actions

## Testing

Add or update tests for:

- account catalog decoding of entitlement expiry
- profile refresh populates expiry alongside usage
- controller persistence keeps refreshed expiry on the profile
- menu bar row presentation prefers expiry over detected-note text when usage exists
- menu bar layout still uses interactive row composition

## Out Of Scope

- manager window redesign
- status-item title redesign
- changing the meaning of `5H` and `7D`
- additional row actions
- switching the panel to a different scene type
