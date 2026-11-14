# Roadmap

Legend: ✅ done and tested · 🟡 partial · ⬜ not started. "Tested" means automated tests exist
(Rust unit/integration, Swift integration, offscreen UI renders).

## Phase 0 — Foundation ✅
- ✅ Workspace layout, docs, ADRs (`DECISIONS.md`)
- ✅ Rust core with C ABI, generated header, panic-safe boundary
- ✅ Structured error model (code, category, message, recovery, details)
- ✅ Content-based detection (magic bytes, ISO-BMFF brands, ZIP flavours, executables, truncation)
- ✅ Capability registry (ImageIO, AVFoundation presets, FFmpeg encoders/muxers/license)
- ✅ Logging (`os.Logger`, private paths)
- ✅ CI workflows (macOS, Windows-core) — written, not yet run on GitHub
- ✅ Golden fixtures + generator (CC0)

## Phase 1 — macOS MVP ✅ (core flows) / 🟡 (polish)
- ✅ Native SwiftUI app, drag & drop, open panel, Finder "Open With"
- ✅ Inspector (image/video/audio/PDF metadata, sensitive-data flags)
- ✅ Image conversion: JPEG/PNG/HEIC/AVIF/TIFF/BMP/GIF via ImageIO, WebP via libwebp; resize,
  sRGB, alpha flattening, lossless metadata removal
- ✅ Video: remux-first convert, make smaller (VideoToolbox HEVC/H.264 + software fallback),
  extract audio (no re-encode when possible), GIF, metadata/location removal
- ✅ Audio: MP3, AAC/M4A, FLAC, ALAC, Opus, WAV, AIFF (FFmpeg); AAC via AVFoundation
- ✅ Queue with backpressure, real progress (pass/attempt/speed/ETA), cancel, retry
- ✅ Output policy (same folder / custom), collisions (rename/replace/skip), originals never touched
- ✅ Sandbox-aware folder access (security-scoped bookmarks)
- ✅ English + Spanish
- 🟡 Release build verified sandboxed end-to-end on a signed build (needs signing identity)
- ✅ Menu bar extra and completion notifications (moved to Phase 2, see below)

## Phase 2 — Signature UX 🟡
- ✅ **Edge Dock** — non-activating `NSPanel` strip per display edge, appears only during file
  drags (no Accessibility, no global monitors), contextual actions from the core, drop starts the
  job with default intents, progress + results with drag-out, held-files fallback (sandbox),
  outer-edge geometry for multi-monitor/mixed scale, Spaces, full-screen opt-out, reduced motion,
  settings (side, sensitivity, displays). Design and manual multi-monitor checklist:
  [`docs/EDGE_DOCK.md`](docs/EDGE_DOCK.md). 🟡 Manual checklist not yet run on real multi-monitor
  hardware.
- ✅ Menu bar extra (open, jobs in progress, recent results, Edge Dock switch, settings, quit;
  can be hidden)
- ✅ Command Palette (⌘K): intents driven by the planner + navigation, bilingual fuzzy search
- ✅ Completion notifications for jobs ≥ 8 s while the app is in the background (permission at
  first need, coalesced)
- ⬜ Configurable keyboard shortcuts; global hot key for the palette
- ⬜ Edge Dock: file-promise drags (Photos, Mail attachments)
- ⬜ Share-ready presets from a versioned, editable catalog (Chat/Email/Web/Discord…)
- 🟡 Advanced mode (codec, encoder, CRF, bitrate, resolution, fps, audio, metadata) — done for
  video/audio/image; missing: container picker, two-pass toggle, subtitle/chapters options

## Phase 3 — Power tools ⬜
- ⬜ PDF (PDFKit): merge, split, reorder, rotate, extract, image→PDF, PDF→images, compress,
  metadata, password-aware (never cracked, never stored)
- ⬜ OCR (Vision, local; es/en; searchable PDF)
- ⬜ Recipes (JSON + schema, editor, import/export, Edge Dock targets)
- ⬜ Batch rename with preview; image → PDF
- ⬜ History (local JSON-lines, retention options, clear)
- ⬜ Interrupted-job journal ("Conversion interrupted — Retry")
- ⬜ SVG input with a sandboxed rasterizer verified not to fetch external resources
- 🟡 Target size — ✅ algorithm, refinement, acceptance test; ⬜ native (AVAssetWriter) path

## Phase 4 — macOS polish ⬜
- ⬜ AVAssetWriter engine with bitrate control (Store build parity)
- ⬜ LGPL FFmpeg build script + bundling for the Direct build
- ⬜ Accessibility audit (VoiceOver walkthrough, keyboard-only, Increase Contrast)
- ⬜ Onboarding (3 screens), diagnostics export with path redaction, log viewer/clear
- ⬜ Benchmarks with stored baseline (startup, inspect 1/100, batch images, encode, memory)
- ⬜ Packaging: DMG, notarization, Mac App Store build

## Phase 5–7 — Windows, integrations, hardening ⬜
WinUI 3 app on the same core (C# P/Invoke), Edge Dock for Windows, tray, Explorer integration,
MSIX; fuzzing, crash recovery, license/privacy/security audits.

## Owner decisions (cannot be made by engineering)
- Final product name and icon (branding is centralized for a rename)
- Commercial license (LICENSE is a placeholder)
- Apple Developer account / Developer ID & Mac App Store identities
- Microsoft Partner Center account and code-signing certificate

## Known limitations (current build)
- Recent results in the menu bar are session-only (persistent history is Phase 3).
- The Edge Dock ignores drags that only carry file promises (e.g. from Photos).
- Without FFmpeg, video "Make smaller" uses AVFoundation presets (no Smaller/Balanced/High
  bitrate control) and target size is unavailable.
- HDR → H.264 has no tone mapping (warned in the plan).
- Animated GIF/WebP input is not converted (refused with a clear message).
- WebP output carries no ICC profile (colors are converted to sRGB first).
