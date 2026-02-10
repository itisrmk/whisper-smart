#!/usr/bin/env bash
# scripts/typecheck.sh — Swift type-check for all sources in the repo.
# Usage: bash scripts/typecheck.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Collect every Swift file under app/
SOURCES=()
while IFS= read -r -d '' f; do
    SOURCES+=("$f")
done < <(find "$REPO_ROOT/app" -name '*.swift' -print0)

if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "No Swift files found under app/."
    exit 1
fi

echo "Type-checking ${#SOURCES[@]} Swift file(s)…"

swiftc -typecheck \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macosx14.0" \
    -F "$(xcrun --show-sdk-path)/System/Library/Frameworks" \
    "${SOURCES[@]}"

echo "✓ All files pass type-check."
