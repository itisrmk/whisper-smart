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

# Hermetic render: point HOME at a scratch dir so the developer's real
# transcript history, session metrics, and defaults never leak into
# snapshots — CI renders clean state and must match baselines.
SNAPSHOT_HOME="$(mktemp -d)"
trap 'rm -rf "$SNAPSHOT_HOME"' EXIT
HOME="$SNAPSHOT_HOME" VISPERFLOW_UI_SNAPSHOT=1 "$VISUAL_BIN"
