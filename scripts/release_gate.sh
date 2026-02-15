#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Release gate: typecheck"
bash scripts/typecheck.sh

echo "==> Release gate: QA smoke"
bash scripts/run_qa_smoke.sh

echo "==> Release gate: production build"
swift build -c release

echo "==> Release gate: DMG package"
bash scripts/package_dmg.sh

DMG_PATH="$REPO_ROOT/.build/release/Whisper-Smart-mac.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "Release gate FAILED: DMG artifact not found at $DMG_PATH" >&2
  exit 1
fi

echo "==> Release gate: DMG checksum"
shasum -a 256 "$DMG_PATH"

echo
echo "Release gate PASSED."
