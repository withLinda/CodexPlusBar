# CodexPlusBar App Icon Brief

- Surface: macOS desktop and menu bar.
- Source of truth: `sketch/AppIcon-master.svg`, edited by the user on 2026-08-17 at 13:57 WIB.
- Purpose: help people choose and manage the right Codex or Claude account from the menu bar.
- Metaphor: a cursor choosing a Codex terminal badge from a menu bar.
- Dominant silhouette: one large dark-to-salmon Codex mark with a terminal prompt cutout.
- Supporting idea: three top menu slots and one large cursor.
- Small-size requirement: the Codex mark, terminal glyph, cursor, and menu slots must remain clear at 64 px.
- Source profile: sRGB; untagged SVG colors are treated as sRGB in Icon Composer.
- Background and subtle tile: stable `#EFEBD4`.
- Codex mark: deliberate vertical gradient from `#543A48` through `#E67E80` to `#543A48`.
- Cursor and menu slots: `#543A48`.
- Cursor separation stroke: `#E5DFC5`.
- Geometry: stacked flat shapes; menu slots are front-most; no source-drawn extrusion.
- Measured foreground bounds: `x 0...1024`, `y 107...853` on the 1024 canvas (100% × 72.8516%, exclusive right/bottom edge).
- Source canvases: 1024 × 1024, full-canvas, untrimmed.
- Platforms: macOS only; watchOS off.

The source becomes five back-to-front layers: background, Codex tile, Codex mark, cursor, and menu slots. The tile and gradient mark are separate because they need different effect behavior. The cursor and slots are separate because the right slot overlaps the cursor and must keep its own material edge. The five layers fit in three Icon Composer groups using Individual mode.

The 100% measured width is intentional: the left and right menu slots bleed past the source canvas and are cropped by the platform mask. The central Codex mark stays safely inside the mask.

The master SVG moves every object, including the background, 20 px to the right. That creates an unintended transparent strip at the left edge. The production background keeps the chosen `#EFEBD4` color but fills the complete 1024 × 1024 canvas. Every foreground transform remains exactly as edited.
