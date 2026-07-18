#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Whisper Smart}"
BUNDLE_ID="${BUNDLE_ID:-com.whispersmart.desktop}"
VERSION="${VERSION:-0.2.14}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
LOGO_PATH="${LOGO_PATH:-$REPO_ROOT/logo.png}"
MLX_RUNNER_SOURCE="$REPO_ROOT/scripts/mlx_stt_infer.py"
# Key rotated 2026-07-17: the original private key was unrecoverable (only
# copy on Rahuls-Mac-mini, never exported), so a new pair was generated.
# Private counterpart: release MacBook login keychain (account
# "WhisperSmart") and the SPARKLE_PRIVATE_KEY repo Actions secret.
# Clients built before v0.2.29 pin the old key and must reinstall manually.
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-Mv5eYpcOvsnI5sqVuJm7SNd21Pb2byLj8i9Hj/yxTiQ=}"
EXPECTED_BUNDLE_ID="com.whispersmart.desktop"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"

BUILD_DIR="$REPO_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$MACOS_DIR/$APP_NAME"

if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Refusing build: bundle id mismatch."
  echo "Expected: $EXPECTED_BUNDLE_ID"
  echo "Received: $BUNDLE_ID"
  echo "Changing bundle id resets macOS permission trust records."
  exit 1
fi

echo "Building release binary for ${APP_NAME}..."
swift build -c release --package-path "$REPO_ROOT"

# Create the bundle AFTER swift build: SwiftPM prunes unknown directories
# inside its product folder during the build, which used to delete the
# freshly created bundle skeleton and fail the copy step below.
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy the built executable
cp "$REPO_ROOT/.build/arm64-apple-macosx/release/$APP_NAME" "$EXECUTABLE_PATH"

# Copy Sparkle framework
mkdir -p "$CONTENTS_DIR/Frameworks"
cp -R "$REPO_ROOT/.build/arm64-apple-macosx/release/Sparkle.framework" "$CONTENTS_DIR/Frameworks/"

# Ensure runtime can find embedded frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH" 2>/dev/null || true

ICON_FILE_NAME="AppIcon.icns"
if [ -f "$LOGO_PATH" ]; then
  echo "Generating app icon from ${LOGO_PATH}..."
  ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$LOGO_PATH" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    size2=$((size * 2))
    sips -z "$size2" "$size2" "$LOGO_PATH" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/$ICON_FILE_NAME"
  rm -rf "$ICONSET_DIR"
fi

cp "$LOGO_PATH" "$RESOURCES_DIR/logo.png" 2>/dev/null || true

if [ ! -f "$MLX_RUNNER_SOURCE" ]; then
  echo "Missing MLX runner script at $MLX_RUNNER_SOURCE"
  exit 1
fi

mkdir -p "$RESOURCES_DIR/scripts"
cp "$MLX_RUNNER_SOURCE" "$RESOURCES_DIR/scripts/mlx_stt_infer.py"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Whisper Smart needs microphone access to transcribe your speech.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Whisper Smart uses speech recognition to convert speech to text.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE_NAME</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/itisrmk/whisper-smart/main/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n -E 's/.*"([^"]*Developer ID Application[^"]*)".*/\1/p' | head -n 1 || true)"
  fi

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ "$ALLOW_ADHOC_SIGNING" == "1" ]]; then
      SIGNING_IDENTITY="-"
      echo "WARNING: no Developer ID identity found; falling back to ad-hoc signing (ALLOW_ADHOC_SIGNING=1)."
      echo "WARNING: ad-hoc signed updates can cause permission reset issues across app updates."
    else
      echo "No Developer ID signing identity found."
      echo "Set CODESIGN_IDENTITY to a Developer ID Application certificate, or run with ALLOW_ADHOC_SIGNING=1 for non-release local builds."
      exit 1
    fi
  fi

  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Applying ad-hoc code signature..."
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
  else
    # Hardened runtime (--options runtime) blocks microphone access unless the
    # audio-input entitlement is granted — without it the app cannot record at
    # all, regardless of the user's TCC permission grant.
    ENTITLEMENTS_FILE="$BUILD_DIR/whisper-smart-entitlements.plist"
    cat > "$ENTITLEMENTS_FILE" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
ENTITLEMENTS
    echo "Applying Developer ID signature: ${SIGNING_IDENTITY}"
    codesign --force --deep --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null
  fi

  SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
  SIGNATURE_KIND="$(printf '%s\n' "$SIGNATURE_INFO" | sed -n -E 's/^Signature=(.*)$/\1/p' | head -n 1)"
  TEAM_ID="$(printf '%s\n' "$SIGNATURE_INFO" | sed -n -E 's/^TeamIdentifier=(.*)$/\1/p' | head -n 1)"
  if [[ "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    if [[ "$SIGNATURE_KIND" == "adhoc" ]]; then
      echo "Build failed: app is ad-hoc signed."
      exit 1
    fi
    if [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" ]]; then
      echo "Build failed: TeamIdentifier missing after signing."
      exit 1
    fi
  fi
fi

echo "App bundle created: ${APP_BUNDLE}"
echo "$APP_BUNDLE"
