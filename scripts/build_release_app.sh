#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Whisper Smart}"
BUNDLE_ID="${BUNDLE_ID:-com.whispersmart.desktop}"
VERSION="${VERSION:-0.2.12}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
LOGO_PATH="${LOGO_PATH:-$REPO_ROOT/logo.png}"
PARAKEET_RUNNER_SOURCE="$REPO_ROOT/scripts/parakeet_infer.py"

BUILD_DIR="$REPO_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$MACOS_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Building release binary for ${APP_NAME}..."
swift build -c release --package-path "$REPO_ROOT"

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

if [ ! -f "$PARAKEET_RUNNER_SOURCE" ]; then
  echo "Missing Parakeet runner script at $PARAKEET_RUNNER_SOURCE"
  exit 1
fi

mkdir -p "$RESOURCES_DIR/scripts"
cp "$PARAKEET_RUNNER_SOURCE" "$RESOURCES_DIR/scripts/parakeet_infer.py"

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
  <string>https://raw.githubusercontent.com/itisrmk/whisper-smart/master/appcast.xml</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Applying ad-hoc code signature..."
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

echo "App bundle created: ${APP_BUNDLE}"
echo "$APP_BUNDLE"
