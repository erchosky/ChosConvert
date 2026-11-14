# Architecture

```
┌──────────────────────────────── macOS app (Swift) ─────────────────────────────────┐
│ Presentation   ChosConvertUI   SwiftUI views · design system · String Catalog       │
│                                AppModel (drop → inspect → smart actions → start)    │
│                                Edge Dock (NSPanel per display) · ⌘K · menu bar      │
│ Application    ChosConvertKit  JobQueue · JobRunner · Inspector · CapabilityService │
│                                OutputAccess (sandbox bookmarks) · TempSpace         │
│ Engines        ImageIOEngine · AVExportEngine · (FFmpeg via core) · PDFKit/Vision*  │
│ Bridge         CoreBridge  ──── C ABI (JSON) ───┐                                   │
└─────────────────────────────────────────────────│───────────────────────────────────┘
┌──────────────────────────── chosconvert-core (Rust) ───────────────────────────────┐
│ api / tasks     JSON dispatch, background tasks with cancellation                   │
│ detect          magic bytes, ISO-BMFF brands, ZIP flavours, truncation, executables │
│ media           MediaInfo model, ffprobe parser                                     │
│ capabilities    CapabilityRegistry, FFmpeg encoder/muxer/license probing            │
│ planner         intent → ConversionPlan (engine, steps, args, estimate, verify)     │
│ executor        FFmpeg passes, HW→SW fallback, verification, target-size refinement │
│ target_size     budget + secant refinement                                          │
│ output / temp   naming, collisions, atomic no-clobber finalize, private temp dirs   │
│ webp            libwebp encoder (BSD)                                               │
└─────────────────────────────────────────────────────────────────────────────────────┘
                     * Phase 3
```

## Flow of one conversion

1. **Drop / open.** `AppModel.add(urls:)` expands folders (hidden files skipped, 10 000 max).
2. **Inspect** (≤ 6 in parallel, off the main thread). The core's `detect.path` reads at most
   8 KB + 64 KB tail to identify the real format, rejecting executables and truncated files.
   Then ImageIO properties (no decode), FFprobe through the core (or AVFoundation), or PDFKit.
3. **Smart actions.** `actions.for_files` asks the planner which intents work for *every*
   selected file with *this* machine's capabilities — impossible actions are never listed.
4. **Configure.** The sheet builds an `Intent` + `AdvancedOptions`; `plan.create` returns steps,
   notes and an estimate (always shown as approximate).
5. **Run.** `JobQueue` applies backpressure per workload kind (image/audio/remux/video HW/SW)
   using `jobs.recommended_concurrency`, then `JobRunner`:
   - creates a private job dir (`temp.create_job_dir`),
   - runs the engine the plan selected (ImageIO, AVFoundation, or `media.execute` in the core),
   - verifies the result (decodes, duration, no leftover location metadata, size rules),
   - finalizes through `OutputAccess` + `output.finalize` (atomic, never touching the source),
   - removes the job dir on success, failure and cancellation.
6. **Result.** Before/after size, reveal/open/copy, drag-out to other apps.

## Where things live

| Concern | Location |
| --- | --- |
| C ABI | `core/chosconvert-ffi`, header `core/include/chosconvert_core.h` |
| Planning rules | `core/chosconvert-core/src/planner/{media,image,native_av,encoders}.rs` |
| Error model | `core/chosconvert-core/src/error.rs` ↔ `ChosConvertKit/Core/ChosError.swift` |
| Design tokens | `ChosConvertUI/DesignSystem/Tokens.swift` (spacing, radius, motion, palette, type) |
| Strings | `ChosConvertUI/Resources/Localizable.xcstrings` |
| Branding | `branding/brand.json`, `macos/App/Config/Brand.xcconfig` |
| Edge Dock | `ChosConvertUI/EdgeDock/*` — design in [docs/EDGE_DOCK.md](docs/EDGE_DOCK.md) |
| Command palette | `ChosConvertUI/Palette/*` |
| Menu bar, notifications | `ChosConvertUI/MenuBar/*` |

## App lifetime
`AppDelegate` owns the single `AppModel`, so the Edge Dock, menu bar extra and Finder "Open With"
work before (or without) the main window. Closing the window keeps the app running. Every entry
point (main window, Edge Dock, ⌘K) enqueues into the same `JobQueue` through `AppModel.enqueue`.

## Concurrency model (Swift)

UI state is `@MainActor @Observable`. Engines run in detached tasks; FFmpeg runs on a core-owned
thread and reports through the C callback into an `AsyncStream`. Swift task cancellation is
forwarded to `cc_task_cancel`, which kills the FFmpeg child. Progress is only shown as a
percentage when the engine reports real progress; otherwise the UI shows an indeterminate bar.

## Error model

Every failure is a `ChosError {code, category, message, recovery[], details}`. The UI shows the
localized `error.<code>` text plus recovery buttons; `details` (stderr tail, OS error) sit behind
"View technical details". Codes are listed in `ErrorCode` in the core.

## Splitting into two repositories
See [CORE_SYNC.md](CORE_SYNC.md).
