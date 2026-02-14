#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

require_cmd xcodegen
require_cmd xcodebuild

echo "[1/5] Bootstrap (regenerate Xcode project from project.yml)"
./Scripts/bootstrap.sh

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[2/5] Drift check against checked-in files"
  if ! git diff --quiet -- iOSWhisperSmart.xcodeproj project.yml; then
    echo "❌ Config drift detected between project.yml and checked-in .xcodeproj"
    echo "Run ./Scripts/bootstrap.sh and commit resulting project changes."
    git --no-pager diff -- iOSWhisperSmart.xcodeproj project.yml || true
    exit 1
  fi
  echo "✅ No drift detected"
else
  echo "[2/5] Skipping git drift check (not in a git work tree)"
fi

echo "[3/5] Verify project target/scheme list includes keyboard extension"
LIST_OUTPUT="$(xcodebuild -list -project iOSWhisperSmart.xcodeproj)"
echo "$LIST_OUTPUT" | grep -q "iOSWhisperSmartKeyboard" || {
  echo "❌ Missing iOSWhisperSmartKeyboard target/scheme in project"
  exit 1
}
echo "✅ Keyboard target/scheme present"

echo "[4/5] Build + test app scheme"
xcodebuild -project iOSWhisperSmart.xcodeproj \
  -scheme iOSWhisperSmart \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build

xcodebuild -project iOSWhisperSmart.xcodeproj \
  -scheme iOSWhisperSmart \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test

echo "[5/5] Build keyboard extension scheme"
xcodebuild -project iOSWhisperSmart.xcodeproj \
  -scheme iOSWhisperSmartKeyboard \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build

echo "✅ Config integrity verification passed"
