# Menu Bar Quiet Premium Sketch Design

Date: 2026-04-21
Surface mode: `menu bar`
Status: approved direction, Sketch implementation in progress

## Goal

Redesign the CodexPlusBar menu bar popup panel in a calmer, more premium way while keeping the same core job:

- show the currently important profile fast
- let users compare other profiles without heavy scanning
- keep common actions visible
- reduce cognitive load for ADHD users who prefer minimal, elegant UI

## Product Rules

- `platform rule`: a menu bar surface should feel like quick access, not a full dashboard
- `research-backed heuristic`: one obvious focal area should answer the main question in under a few seconds
- `research-backed heuristic`: do not make every profile compete equally for attention
- `conditional heuristic`: use Liquid Glass mostly in chrome and controls, not on the main reading surfaces

## Chosen Direction

Use `pinned profile first, others below`.

Analogy:
This should feel like a valet tray on a desk.
The item you use most is placed in the best spot.
Everything else is still present, but quieter and neatly arranged.

That means:

- top area: one featured pinned profile block
- middle area: compact matte rows for other profiles
- bottom area: a tiny utility rail for global actions

## Information Hierarchy

### 1. Featured top profile

This is the primary visual anchor.

It should show:

- profile label
- active state
- `5H` and `7D` usage
- entitlement expiry
- visible fast actions

It should visually explain:
`this is the profile currently driving the menu bar`.

### 2. Other profiles

These rows stay visible, but lighter and flatter than the hero.

Each row should show:

- profile label
- compact `5H` and `7D` values
- expiry
- quiet actions
- a visible control to move that profile to the top

### 3. Utility rail

Global actions belong at the bottom in a very small strip:

- refresh all
- open manager
- quit

These should not fight with the profile content for attention.

## Layout

Keep the current panel footprint as the implementation-friendly base:

- width: `484`
- height: `560`

Internal layout:

- outer shell with soft radius and subtle depth
- very light top chrome strip
- hero card near the top with generous breathing room
- short label for the secondary list, such as `Other profiles`
- compact row stack below
- small bottom utility rail

## Visual System

Follow the existing Everforest dark language already present in the app.

Palette:

- base: `#1E2326`, `#272E33`, `#2E383C`
- text: `#D3C6AA`
- muted text: `#7A8478`, `#859289`, `#9DA9A0`
- warm emphasis: `#E69875`, `#E67E80`, `#DBBC7F`

Shape:

- shell radius `18`
- hero and main surfaces `16`
- nested rows `12`
- icon buttons `10`
- chips `8`

Depth:

- keep content matte first
- let the shell and small control clusters carry the glass-like lightness
- use warm glow very lightly, mostly as atmosphere in the background, not as borders everywhere

Typography:

- use `Inter` for compact utility text and dense labels
- use one strong title size only where it improves orientation
- do not add helper copy unless it changes the next action

## Interaction Model

### Featured profile

- tapping the main block opens the manager for that profile
- fast actions stay visible in the block
- pinned state is obvious from placement, so it does not need loud labeling

### Other rows

- tapping a row opens the manager for that profile
- copy and email stay available as quiet icon actions
- `Show on top` stays visible as the single warm accent control

### Utility rail

- all actions use compact icon treatment
- the rail should read as support chrome, not as content

## Accessibility And ADHD Guardrails

- do not rely on color alone for urgency
- keep one dominant focal block only
- avoid decorative status cards or duplicate metadata
- keep labels short and familiar
- keep repeated row structure consistent so users can resume quickly after distraction
- keep disabled actions visible when they teach the feature set clearly

## Sketch Deliverables

Create these items in Sketch:

1. a page for the menu bar redesign
2. one main artboard for the full popup panel
3. a small component area for reusable row and button parts

## Out Of Scope

- redesigning the manager window
- changing backend data meaning
- changing the menu bar status item text format
- adding new profile actions
- turning the popup into a mini dashboard app

## Success Check

The panel is successful if it feels:

- calm on first open
- obvious in what matters now
- elegant without decorative waste
- easy to resume after distraction
- visually premium, but still faster to scan than the current layout
