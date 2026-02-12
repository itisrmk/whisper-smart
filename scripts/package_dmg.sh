#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Whisper Smart}"
DMG_NAME="${DMG_NAME:-Whisper-Smart-mac.dmg}"
BUILD_DIR="$REPO_ROOT/.build/release"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

"$REPO_ROOT/scripts/build_release_app.sh" >/dev/null
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "Expected app bundle not found: $APP_BUNDLE"
  exit 1
fi

rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "Creating DMG…"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"

echo "✅ DMG created: $DMG_PATH"
echo "$DMG_PATH"
