# Whisper Smart — DMG Release Guide (Non-App-Store)

This project now ships with scripts to build a signed `.app` bundle and package a `.dmg` for distribution via website/GitHub.

## Prerequisites (macOS)
- Xcode Command Line Tools (`xcode-select --install`)
- `swiftc`, `sips`, `iconutil`, `hdiutil` available in PATH
- `logo.png` in repo root (used for app icon)

## 1) Build release app bundle

```bash
cd VisperflowClone
bash scripts/build_release_app.sh
```

Output:
- `.build/release/Whisper Smart.app`

## 2) Package DMG

```bash
bash scripts/package_dmg.sh
```

Output:
- `.build/release/Whisper-Smart-mac.dmg`

## 3) Quick local verification

```bash
open .build/release/Whisper-Smart-mac.dmg
```

- Mounts volume `Whisper Smart`
- Contains:
  - `Whisper Smart.app`
  - `Applications` symlink

## Optional release env overrides

```bash
APP_NAME="Whisper Smart" \
BUNDLE_ID="com.whispersmart.desktop" \
VERSION="0.2.3" \
BUILD_NUMBER="20260211" \
LOGO_PATH="$(pwd)/logo.png" \
bash scripts/build_release_app.sh
```

## Important for public distribution

Ad-hoc signing is enough for local testing, but public users will see Gatekeeper warnings unless you:
1. Sign with Apple Developer ID certificate
2. Notarize the app/DMG
3. Staple notarization ticket

Recommended before wide release.
