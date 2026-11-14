# Contributing

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) and [DECISIONS.md](DECISIONS.md). Significant choices get
   a new ADR.
2. Build and test with `scripts/test-macos.sh` (BUILDING.md). CI must stay green.
3. **Definition of done** for a feature: it works; handles errors with a `ChosError` code that has
   `error.<code>` strings; supports cancellation where it runs long; never blocks the main thread;
   has tests (unit + fixture-based integration); is accessible (labels, keyboard, VoiceOver);
   looks right in light and dark; all strings are in the String Catalog (en + es); logs without
   private data; makes no network requests.
4. No fake features: no buttons that do nothing, no simulated progress, no hard-coded results.
   If something isn't ready, it is not shown.

## Code style
- **Rust:** `cargo fmt`, `cargo clippy -D warnings`; typed errors (`AppError`), no `unwrap()`/
  `expect()` outside tests; `unsafe` only in the FFI and libwebp wrapper, each block with a
  `SAFETY:` comment.
- **Swift:** Swift 6 strict concurrency; `@MainActor` UI state; typed throws with `ChosError`;
  no force unwraps in production paths; design tokens (`DS.*`) instead of literal styling;
  `Text(l:)` / `L.s` for every user-facing string.
- **Commits:** small and focused; describe *why*.
