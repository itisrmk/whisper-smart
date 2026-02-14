#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen"
  exit 1
fi

xcodegen generate

echo "Generated iOSWhisperSmart.xcodeproj from project.yml"
echo "Run ./Scripts/verify_config_integrity.sh for drift + build/test verification"
