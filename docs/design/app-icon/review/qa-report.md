# CodexPlusBar App Icon QA Report

Status: **PASS**
Date: 2026-08-17
Target: macOS Only

![Final CodexPlusBar app icon](<user-svg-refresh-20260817-1401/AppIcon Exports/AppIcon-macOS-Default-1024x1024@1x.png>)

## Result

The user-edited SVG is now the official CodexPlusBar app icon.

- The icon shows three menu slots, one large cursor, and one Codex terminal mark.
- Default keeps the edited pale, plum, and salmon colors.
- Dark, Clear, and Tinted use Icon Composer's system adaptations but keep the same shapes and layer order.
- The accidental 20 px clear strip from the master background transform is fixed only in the production background layer.
- The user's master SVG was not changed. Its SHA-256 is `041c0745d22163d4d9ebb931aacb0722a4ca58bfbece7ea183ac49aae46fd937`.
- `Resources/AppIcon.icon` is the official macOS-only Icon Composer document used by Xcode.

## Icon Composer layers

| Back to front | Group | Layer | Material result |
|---:|---|---|---|
| 1 | `01_background` | `01_background.svg` | Exact warm full-bleed field; layer effects off |
| 2 | `02_codex-tile` | `02_codex-tile.svg` | Quiet supporting tile; layer effects on |
| 3 | `03_codex-logo` | `03_codex-mark.svg` | Edited plum-to-salmon gradient; layer effects off |
| 4 | `03_codex-logo` | `04_cursor.svg` | Exact cursor and pale boundary; layer effects off |
| 5 | `04_menu-slots` | `05_menu-slots.svg` | Front-most menu slots; restrained layer effects on |

All four groups use Individual mode. Specular, blur, and translucency are off at group level. Every imported layer stayed at X 0 pt, Y 0 pt, and 100% scale.

## Visual checks

- Visible source bounds are `[0, 107, 1024, 853]`, or 100% wide and 72.8516% high. The full width is the deliberate menu-slot bleed.
- The Apple grid shows a centered main Codex mark and safe mask spacing.
- Default was checked at 1024, 128, and 64 px.
- Default was checked near -48°, +89°, and -170° light angles.
- Default, Dark, and Mono were checked on the solid preview and the built-in image background.
- Default, Dark, Clear Light, Clear Dark, Tinted Light, and Tinted Dark exports were checked at 1024 and 64 px.
- The compiled 256, 128, and 16 px macOS icons were inspected. The terminal mark, cursor, and menu slots remain recognizable.

## Color checks

| Essential pair | WCAG contrast | ΔL* D50 | Result |
|---|---:|---:|---|
| Dark recognizer `#543A48` on field `#EFEBD4` | 8.432648:1 | 65.064489 | Pass |
| Cursor boundary `#E5DFC5` on cursor `#543A48` | 7.560076:1 | 60.947381 | Pass |

The salmon midpoint `#E67E80` on `#EFEBD4` is 2.284948:1 with ΔL* 28.045708. This is accepted as supporting gradient color because the dark gradient ends, cursor, menu slots, and terminal silhouette remain the main recognizers.

## Technical checks

- Source audit: 5 SVG files, 0 PNG source layers, 0 errors, 0 warnings.
- Icon Composer structure: 5 layers in 4 ordered groups.
- Platform settings after final reopen: macOS Only on, watchOS off, untagged SVG Display P3 treatment off.
- Native export: 60 PNG files.
- PNG decoding: 60 of 60 passed.
- Exported appearances: Default, Dark, Clear Light, Clear Dark, Tinted Light, and Tinted Dark.
- Exported pixel sizes: 16, 32, 64, 128, 256, 512, and 1024.
- Save/reopen check: passed from the absolute `Resources/AppIcon.icon` path.
- Strict macOS Debug build: passed with warnings treated as errors.
- Xcode `actool` consumed `Resources/AppIcon.icon` with app-icon name `AppIcon`.
- Built app output contains `AppIcon.icns` and `Assets.car`.
- Built app contains no loose icon JSON or SVG source files.
- Built `Info.plist` has both `CFBundleIconFile` and `CFBundleIconName` set to `AppIcon`.
- Final manifest validation: passed with no errors or warnings.

## Main files

- Editable Sketch source: [`../sketch/AppIcon-master-20260817-1357.sketch`](../sketch/AppIcon-master-20260817-1357.sketch)
- User-edited master SVG: [`../sketch/AppIcon-master.svg`](../sketch/AppIcon-master.svg)
- Layer preview: [`../layers/preview.html`](../layers/preview.html)
- Official Icon Composer file: [`../../../../Resources/AppIcon.icon`](../../../../Resources/AppIcon.icon)
- Production manifest: [`../icon-project-manifest.json`](../icon-project-manifest.json)
- Native review exports: [`user-svg-refresh-20260817-1401/AppIcon Exports`](<user-svg-refresh-20260817-1401/AppIcon Exports>)
- Compiled macOS iconset: [`user-svg-refresh-20260817-1401/built-app-refresh-20260817-1437.iconset`](user-svg-refresh-20260817-1401/built-app-refresh-20260817-1437.iconset)
- Neighbor scale comparison: [`neighbor-comparison.png`](neighbor-comparison.png)
- Pre-refresh backup: [`../work/checkpoint-before-user-svg-refresh-20260817-1401`](../work/checkpoint-before-user-svg-refresh-20260817-1401)

The workflow follows Apple's current [Icon Composer documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) and [Icon Composer overview](https://developer.apple.com/icon-composer/).
