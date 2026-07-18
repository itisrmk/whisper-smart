#!/usr/bin/env bash
# Build and launch Whisper Smart as a proper .app bundle for local dev.
#
# The raw SwiftPM binary CANNOT be run directly: requesting microphone
# access without an Info.plist usage description makes TCC abort the
# process (__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__). So this script
# wraps the debug binary in a minimal signed bundle first.
#
# Usage:
#   bash scripts/run_dev.sh               # build + launch
#   bash scripts/run_dev.sh --fresh       # reset onboarding + provider first,
#                                         # so the first-run onboarding window
#                                         # appears on launch
#   bash scripts/run_dev.sh --onboarding  # reset only the onboarding flag
#   bash scripts/run_dev.sh --release     # release build instead of debug
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Whisper Smart"
BUNDLE_ID="com.whispersmart.desktop"   # immutable — changing it resets TCC grants
CONFIG=debug
RESET_ONBOARDING=0
RESET_PROVIDER=0

for arg in "$@"; do
  case "$arg" in
    --release)    CONFIG=release ;;
    --fresh)      RESET_ONBOARDING=1; RESET_PROVIDER=1 ;;
    --onboarding) RESET_ONBOARDING=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Only one instance can own the menu-bar item and the CGEvent tap.
pkill -x "$APP_NAME" 2>/dev/null || true

reset_key() {
  defaults delete "$BUNDLE_ID" "$1" 2>/dev/null || true
  defaults delete "$APP_NAME" "$1" 2>/dev/null || true
}

if [[ $RESET_ONBOARDING -eq 1 ]]; then
  reset_key "productOnboarding.completed.v1"
  echo "→ Onboarding completion flag reset."
fi
if [[ $RESET_PROVIDER -eq 1 ]]; then
  reset_key "selectedSTTProvider"
  echo "→ Provider selection reset (fresh-install gate satisfied)."
fi

swift build -c "$CONFIG"

# ── Assemble a minimal dev .app bundle ───────────────────────────────
PRODUCTS=".build/$CONFIG"
BUNDLE_DIR=".build/dev-bundle-$CONFIG"
APP_BUNDLE="$BUNDLE_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp "$PRODUCTS/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"

if [ -d "$PRODUCTS/Sparkle.framework" ]; then
  cp -R "$PRODUCTS/Sparkle.framework" "$CONTENTS/Frameworks/"
fi
if [ -d "$PRODUCTS/WhisperSmart_App.bundle" ]; then
  cp -R "$PRODUCTS/WhisperSmart_App.bundle" "$CONTENTS/Resources/"
fi
mkdir -p "$CONTENTS/Resources/scripts"
cp scripts/mlx_stt_infer.py "$CONTENTS/Resources/scripts/mlx_stt_infer.py"

install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0-dev</string>
  <key>CFBundleVersion</key>
  <string>0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Whisper Smart needs microphone access to transcribe your speech.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Whisper Smart uses speech recognition to convert speech to text.</string>
  <key>SUEnableAutomaticChecks</key>
  <false/>
</dict>
</plist>
PLIST

# Sign with an Apple Development identity when available so TCC grants
# survive rebuilds; otherwise fall back to ad-hoc (grants may re-prompt
# after every build). Sign by SHA-1 hash, not name — a revoked cert with
# the same name in the keychain makes name-based signing ambiguous.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Development" | grep -v CSSMERR | head -n 1 \
  | awk '{print $2}' || true)"
if [[ -n "$IDENTITY" ]]; then
  echo "→ Signing with identity: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1
else
  echo "→ No Apple Development identity; ad-hoc signing (permissions may re-prompt after rebuilds)."
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

echo "→ Launching $APP_BUNDLE"
echo "  Look for the mic icon in the macOS menu bar. Ctrl+C here quits the app."
exec "$CONTENTS/MacOS/$APP_NAME"
