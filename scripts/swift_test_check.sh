#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_FILE="$REPO_ROOT/Package.swift"

if [ ! -f "$PACKAGE_FILE" ] || ! grep -q "\.testTarget\s*(" "$PACKAGE_FILE"; then
  echo "No SwiftPM test target is declared in Package.swift."
  echo "Skipping 'swift test' by design; QA coverage is provided by scripts/run_qa_smoke.sh."
  exit 0
fi

cd "$REPO_ROOT"
swift test
