#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VISUAL_BIN="$REPO_ROOT/.build/visual-regression"
mkdir -p "$(dirname "$VISUAL_BIN")"

CORE_SOURCES=()
while IFS= read -r -d '' f; do
  CORE_SOURCES+=("$f")
done < <(find "$REPO_ROOT/app/Core" -name '*.swift' -print0)

swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -F "$(xcrun --show-sdk-path)/System/Library/Frameworks" \
  "${CORE_SOURCES[@]}" \
  "$REPO_ROOT/app/UI/DesignTokens.swift" \
  "$REPO_ROOT/app/UI/SettingsView.swift" \
  "$REPO_ROOT/tests/visual/settings_visual_regression.swift" \
  -o "$VISUAL_BIN"

VISPERFLOW_UI_SNAPSHOT=1 "$VISUAL_BIN"
