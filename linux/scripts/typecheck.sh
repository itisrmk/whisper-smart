#!/usr/bin/env bash
# Type-checks without producing a binary. Mirrors the macOS typecheck script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec cargo check --all-targets
