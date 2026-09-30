#!/usr/bin/env bash
# Builds the release zip published alongside the macOS DMG and Linux tarball.
#
# Runs under Git Bash / MSYS on the Windows CI runner. The zip is deliberately
# self-contained and relocatable: one folder with the exe, the Python STT
# sidecar, and a short README — unzip anywhere and run whisper-smart.exe.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

VERSION="${VERSION:-$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)}"
ARCH="${ARCH:-x86_64}"
NAME="whisper-smart-${VERSION}-windows-${ARCH}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/dist}"
STAGE="$OUT_DIR/$NAME"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    say "Building release binary"
    cargo build --release --locked
fi

BINARY="$REPO_DIR/target/release/whisper-smart.exe"
[[ -f "$BINARY" ]] || { echo "No binary at $BINARY (build first, or unset SKIP_BUILD)" >&2; exit 1; }

say "Staging $NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/python"
cp "$BINARY" "$STAGE/whisper-smart.exe"
cp "$REPO_DIR/python/stt_daemon.py" "$STAGE/python/stt_daemon.py"
cp "$REPO_DIR/README.md" "$STAGE/README.md"

cat > "$STAGE/GETTING-STARTED.txt" <<'NOTES'
Whisper Smart for Windows
=========================

1. Run whisper-smart.exe. The app lives in the notification area (system
   tray) — there is no main window until you open Settings from the tray.
2. In Settings -> Provider, press "Install whisper.cpp" and download a model
   (Balanced is a good start).
3. Hold Right Ctrl, speak, release. The transcript is inserted where your
   cursor is. Double-press Right Ctrl for hands-free mode; Esc cancels.

Windows SmartScreen may warn about an unsigned app on first launch: choose
"More info" -> "Run anyway".

To start with Windows, create a shortcut to whisper-smart.exe inside the
Startup folder (Win+R, then: shell:startup).

Command-line checks (run from a terminal in this folder):
    whisper-smart.exe --check
    whisper-smart.exe --mic-test
    whisper-smart.exe --list-models
NOTES

say "Compressing"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$NAME.zip"
if command -v powershell.exe >/dev/null 2>&1; then
    # The CI path: Compress-Archive ships with Windows.
    powershell.exe -NoProfile -Command \
        "Compress-Archive -Path '$(cygpath -w "$STAGE")' -DestinationPath '$(cygpath -w "$OUT_DIR/$NAME.zip")' -Force"
else
    # Local fallback for Unix hosts with the zip tool installed.
    (cd "$OUT_DIR" && zip -qr "$NAME.zip" "$NAME")
fi
( cd "$OUT_DIR" && sha256sum "$NAME.zip" > "$NAME.zip.sha256" )
rm -rf "$STAGE"

say "Built $OUT_DIR/$NAME.zip"
du -h "$OUT_DIR/$NAME.zip"
cat "$OUT_DIR/$NAME.zip.sha256"
