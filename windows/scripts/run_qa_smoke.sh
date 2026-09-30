#!/usr/bin/env bash
# Runs the full test suite plus the lint and format gates.
# Mirrors linux/scripts/run_qa_smoke.sh; runs under Git Bash on Windows CI
# and on Unix development hosts alike.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail=0

say "Formatting"
cargo fmt --check || { echo "run: cargo fmt"; fail=1; }

say "Lints"
cargo clippy --all-targets -- -D warnings || fail=1

say "Tests"
cargo test || fail=1

say "Python sidecar syntax"
PYTHON="$(command -v python3 || command -v python)"
"$PYTHON" -m py_compile python/stt_daemon.py && echo "ok" || fail=1

if (( fail )); then
    say "FAILED"
    exit 1
fi
say "All checks passed"
