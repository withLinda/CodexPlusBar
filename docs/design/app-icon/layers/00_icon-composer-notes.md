# Icon Composer Notes

- Source authority: `../sketch/AppIcon-master.svg`, edited by the user on 2026-08-17 at 13:57 WIB.
- Canvas and color contract: 1024 × 1024, sRGB.
- Background: one opaque full-bleed `#EFEBD4` layer with effects off.
- Geometry: flat stacked artwork; no drawn extrusion.
- Layer order: background, Codex tile, Codex mark, cursor, menu slots.
- Final groups, back to front: `01_background`, `02_codex-tile`, `03_codex-logo` (mark + cursor), and `04_menu-slots`.
- The cursor and menu slots are separate imported layers because they overlap and need independent material edges.
- The left and right menu slots intentionally bleed beyond the canvas. Keep their source coordinates unchanged.
- The user's +20 px foreground shift is preserved. It is removed only from the background so no transparent strip reaches the system mask.
- Preserve the Codex mark gradient `#543A48 → #E67E80 → #543A48` with layer effects off.
- Layer effects: background off, tile on, Codex mark off, cursor off, menu slots on.
- Every group uses Individual mode with specular, blur, and translucency off and a neutral shadow.
- Expected import transform for every layer: x 0, y 0, scale 100%, rotation 0.
- Supported platform: macOS. watchOS stays off.
- Canonical file: `../../../../Resources/AppIcon.icon`. It was saved, closed, reopened, and compiled successfully by Xcode.
