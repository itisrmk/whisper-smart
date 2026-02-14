#!/usr/bin/env bash
# scripts/typecheck.sh — Swift type-check using SwiftPM package context.
# Usage: bash scripts/typecheck.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$REPO_ROOT"

echo "Type-checking App target via SwiftPM (resolves package dependencies like Sparkle)…"
swift build --target App -c debug

echo "✓ App target type-check/build passed."
