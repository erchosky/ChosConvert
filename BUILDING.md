# Building

## Toolchain (verified 2026-10-18)

| Tool | Version | Notes |
| --- | --- | --- |
| macOS | 27.0.1 (build host) | deployment target 15.0 |
| Xcode | 27.1 (Swift 6.4) | Swift 6 language mode |
| Rust | 1.99.1 stable (via rustup) | pinned to `stable` in `core/rust-toolchain.toml` |
| cbindgen | 0.29.4 | header generation (optional: header is committed) |
| XcodeGen | 2.46.0 | generates `ChosConvert.xcodeproj` |
| FFmpeg | any, optional | dev only; Release builds never use a system FFmpeg |

Rust crates (resolved from crates.io, latest stable on 2026-10-18): serde 1.0.229, serde_json
1.0.154, thiserror 2.0.21, uuid 1.28.0, libwebp-sys 0.14.4. No preview/beta dependencies.

## One-time setup

```bash
brew install rustup cbindgen xcodegen
```

```bash
rustup default stable
```

## Build and test everything

```bash
scripts/test-macos.sh
```

This runs `cargo fmt --check`, `cargo clippy -D warnings`, all Rust tests (including the FFmpeg
integration tests when an FFmpeg is installed), rebuilds the core XCFramework and runs the Swift
package tests.

> Build products go to `~/Library/Caches/ChosConvert/build`. Building inside an iCloud-synced
> folder (e.g. `~/Documents`) adds Finder metadata to bundles and breaks code signing.

## The app

```bash
scripts/build-core-macos.sh
```

```bash
cd macos/App && xcodegen generate && open ChosConvert.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project macos/App/ChosConvert.xcodeproj -scheme ChosConvert -configuration Debug -derivedDataPath ~/Library/Caches/ChosConvert/build/xcode build
```

Debug builds are unsandboxed and will use an FFmpeg from `/opt/homebrew/bin`, `/usr/local/bin`
or the path set in Settings ▸ Advanced. Release builds are sandboxed and universal
(`UNIVERSAL=1 scripts/build-core-macos.sh` first).

## Other checks

```bash
python3 scripts/check-l10n.py
```

```bash
scripts/check-offline.sh
```

Slow acceptance test (100 MB+ → 10 MB target):

```bash
cd core && cargo test --release --test ffmpeg_integration acceptance -- --ignored --nocapture
```

Regenerate fixtures, screenshots and the provisional icon:

```bash
scripts/make-fixtures.sh
```

```bash
CC_SNAPSHOTS=1 swift test --package-path macos/ChosConvertKit --scratch-path ~/Library/Caches/ChosConvert/build/spm --filter SnapshotRenderer
```

```bash
swift scripts/render-icon.swift macos/App/Resources/Assets.xcassets/AppIcon.appiconset
```
