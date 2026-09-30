#!/usr/bin/env bash
# Type-check only, no execution. Mirrors linux/scripts/typecheck.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo check --all-targets
