#!/usr/bin/env bash
# Runs the app from the source tree with verbose logging.
# Mirrors scripts/run_dev.sh in the macOS build.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Point the sidecar lookup at the source tree so an installed copy is not used
# by accident while developing.
export WHISPER_SMART_STT_SCRIPT="$PWD/python/stt_daemon.py"
export RUST_LOG="${RUST_LOG:-whisper_smart=debug}"
export RUST_BACKTRACE="${RUST_BACKTRACE:-1}"

exec cargo run "$@"
