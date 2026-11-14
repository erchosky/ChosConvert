# Release process (macOS)

Everything up to signing is automated; only the identities are external.

## 1. Validate
```bash
scripts/test-macos.sh && python3 scripts/check-l10n.py && scripts/check-offline.sh
```
Also run the slow target-size acceptance test (BUILDING.md).

## 2. Build universal Release
```bash
UNIVERSAL=1 scripts/build-core-macos.sh
```
```bash
xcodebuild -project macos/App/ChosConvert.xcodeproj -scheme ChosConvert -configuration Release -derivedDataPath ~/Library/Caches/ChosConvert/build/release archive -archivePath ~/Library/Caches/ChosConvert/build/ChosConvert.xcarchive
```

## 3. Manual sandbox checklist (Release build)
- Drop a file from Desktop → convert "next to original" → folder permission prompt appears once,
  later conversions in that folder don't prompt.
- Custom output folder survives relaunch (bookmark).
- Little Snitch / `nettop -p ChosConvert`: **zero** connections during inspect + image + video +
  audio conversions (PRIVACY acceptance test).
- Offline: Wi-Fi off, all of the above still work.
- Hostile names (`;rm.mov`, `--help.mov`, `"video".mov`, `vídeo ñ.mov`, `$HOME.mov`) convert.

## 4. Distribution variants
| Variant | FFmpeg | Entitlements | Signing |
| --- | --- | --- | --- |
| Direct (DMG) | LGPL build in `Contents/Helpers` (ADR-0005) | `ChosConvert.entitlements` + helper with `app-sandbox` + `inherit` | Developer ID Application, hardened runtime, notarized |
| Mac App Store | none (native engines) | `ChosConvert.entitlements` | Apple Distribution + provisioning profile |

Release validation must fail if a bundled `ffmpeg -version` reports `--enable-gpl` or
`--enable-nonfree`.

## 5. External steps (owner)
1. Set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` (never committed) via a local
   `Config/Signing.local.xcconfig` included by Release.xcconfig, or Xcode's signing UI.
2. Notarize: `xcrun notarytool submit ChosConvert.dmg --keychain-profile <profile> --wait`,
   then `xcrun stapler staple ChosConvert.dmg`.
3. Mac App Store: create the app record (bundle id `app.chosconvert.mac` or the final one from
   `Brand.xcconfig`) and upload with Xcode Organizer / `xcrun altool`.

## Updates
No auto-updater and no network calls. Store builds update through the store; Direct builds
publish new DMGs on the website/GitHub Releases and users update manually.
