#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_BIN="$REPO_ROOT/.build/qa-smoke"
mkdir -p "$(dirname "$SMOKE_BIN")"

CORE_SOURCES=()
while IFS= read -r -d '' f; do
  CORE_SOURCES+=("$f")
done < <(find "$REPO_ROOT/app/Core" -name '*.swift' -print0)

swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -F "$(xcrun --show-sdk-path)/System/Library/Frameworks" \
  "${CORE_SOURCES[@]}" \
  "$REPO_ROOT/tests/smoke/qa_smoke.swift" \
  -o "$SMOKE_BIN"

"$SMOKE_BIN"
