#!/usr/bin/env bash
# Builds the Rust core as a static library, regenerates the C header and packages both as
# ChosConvertCore.xcframework for the Swift package.
#
#   scripts/build-core-macos.sh            # release, host architecture (fast dev builds)
#   UNIVERSAL=1 scripts/build-core-macos.sh  # release, arm64 + x86_64 (distribution)
#   PROFILE=debug scripts/build-core-macos.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PROFILE="${PROFILE:-release}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
[ -d /opt/homebrew/opt/rustup/bin ] && export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
else
  case "$(uname -m)" in
    arm64) TARGETS=(aarch64-apple-darwin) ;;
    *) TARGETS=(x86_64-apple-darwin) ;;
  esac
fi

CARGO_FLAGS=()
[ "$PROFILE" = "release" ] && CARGO_FLAGS+=(--release)

LIBS=()
for t in "${TARGETS[@]}"; do
  echo "› cargo build ($PROFILE, $t)"
  (cd "$CORE" && cargo build -p chosconvert-ffi --target "$t" "${CARGO_FLAGS[@]}" --quiet)
  LIBS+=("$CORE/target/$t/$PROFILE/libchosconvert_ffi.a")
done

STAGE="$CORE/target/xcframework-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE/include"
if [ "${#LIBS[@]}" -gt 1 ]; then
  lipo -create "${LIBS[@]}" -output "$STAGE/libchosconvert_ffi.a"
else
  cp "${LIBS[0]}" "$STAGE/libchosconvert_ffi.a"
fi

echo "› cbindgen"
if command -v cbindgen >/dev/null; then
  (cd "$CORE" && cbindgen --quiet --config chosconvert-ffi/cbindgen.toml --crate chosconvert-ffi \
     --output include/chosconvert_core.h chosconvert-ffi)
else
  echo "  cbindgen not installed; using committed core/include/chosconvert_core.h"
fi
cp "$CORE/include/chosconvert_core.h" "$STAGE/include/"
cat > "$STAGE/include/module.modulemap" <<'MAP'
module CChosConvertCore {
    header "chosconvert_core.h"
    export *
}
MAP

DEST="$ROOT/macos/ChosConvertKit/Frameworks/ChosConvertCore.xcframework"
rm -rf "$DEST"
xcodebuild -create-xcframework -library "$STAGE/libchosconvert_ffi.a" -headers "$STAGE/include" \
  -output "$DEST" >/dev/null
echo "✓ $(lipo -archs "$STAGE/libchosconvert_ffi.a") → ${DEST#$ROOT/}"
