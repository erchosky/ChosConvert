#!/usr/bin/env bash
# Runs all macOS-side tests: Rust core (unit + FFmpeg integration) and the Swift package.
# Build products go to a cache directory outside the source tree: iCloud-synced folders add
# Finder metadata that breaks code signing of test bundles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${CC_SCRATCH:-$HOME/Library/Caches/ChosConvert/build}"
[ -d /opt/homebrew/opt/rustup/bin ] && export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

echo "== Rust core"
(cd "$ROOT/core" && cargo fmt --check && cargo clippy --all-targets --quiet -- -D warnings && cargo test --quiet)

if [ ! -d "$ROOT/macos/ChosConvertKit/Frameworks/ChosConvertCore.xcframework" ] || [ "${REBUILD_CORE:-1}" = "1" ]; then
  "$ROOT/scripts/build-core-macos.sh"
fi

echo "== Swift package"
swift test --package-path "$ROOT/macos/ChosConvertKit" --scratch-path "$SCRATCH/spm" "$@"
