# App icon specification

**Status:** provisional icon rendered by `scripts/render-icon.swift`. The final icon is a product
decision for the owner (see ROADMAP "Owner decisions").

## Concept
Files · transformation · movement · simplicity. Two document silhouettes — the source (translucent,
behind) and the result (solid, in front) — with a short arrow carried *inside* the result, reading
as "this file became that file". No letters, no format names, no brand references to other apps.

## Rules
- macOS: follow the current macOS icon grid (rounded-rect body ≈ 824/1024, soft drop shadow).
  Windows: Fluent-style flat glyph on a plate, 16/20/24/32/48/256 px assets plus a monochrome
  tray icon.
- Must stay legible at 16 px: at that size only the front document + arrow remain distinct.
- Palette: ChosConvert indigo (`#4F54DB` light / `#8F99FF` dark) gradient; white documents.
  Never orange (avoids association with competitors).
- Provide light, dark and tinted variants (macOS 26+ icon appearances) and a monochrome
  template image for the menu bar extra.

## Deliverables for the final icon
`.icon` (Icon Composer) or 1024 px master + appiconset; Windows `.ico` + MSIX visual assets;
menu-bar template PDF (18 pt); tray `.ico` (16/20/24/32).
