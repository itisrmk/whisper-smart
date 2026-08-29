#!/usr/bin/env bash
# Installs Whisper Smart for the current user, with no root required.
#
# Everything lands under ~/.local, which is on the default PATH and XDG data
# path, so this needs neither sudo nor a package manager. For a system-wide
# install, use the PKGBUILD instead.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/whisper-smart"
DESKTOP_DIR="$PREFIX/share/applications"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> %s\033[0m\n' "$*" >&2; }

say "Building release binary"
cargo build --release --manifest-path "$REPO_DIR/Cargo.toml"

say "Installing to $PREFIX"
install -Dm755 "$REPO_DIR/target/release/whisper-smart" "$BIN_DIR/whisper-smart"
# The Python sidecar sits next to the binary's lib directory; runtime.rs looks
# for it at <prefix>/lib/whisper-smart/stt_daemon.py.
install -Dm644 "$REPO_DIR/python/stt_daemon.py" "$LIB_DIR/stt_daemon.py"
install -Dm644 "$REPO_DIR/packaging/whisper-smart.desktop" "$DESKTOP_DIR/whisper-smart.desktop"

# The packaged unit points at /usr/bin; rewrite it for a user-prefix install.
install -d "$UNIT_DIR"
sed "s|^ExecStart=.*|ExecStart=$BIN_DIR/whisper-smart|" \
    "$REPO_DIR/packaging/whisper-smart.service" > "$UNIT_DIR/whisper-smart.service"
systemctl --user daemon-reload 2>/dev/null || true

if ! command -v whisper-smart >/dev/null 2>&1; then
    warn "$BIN_DIR is not on your PATH. Add it to your shell profile:"
    warn "    export PATH=\"\$PATH:$BIN_DIR\""
fi

say "Checking the setup"
"$BIN_DIR/whisper-smart" --check || true

cat <<MSG

Installed.

  Start now:            systemctl --user start whisper-smart
  Start at login:       systemctl --user enable --now whisper-smart
  Follow the log:       journalctl --user -u whisper-smart -f
  Re-run the checks:    whisper-smart --check

Anything reported as FAIL above needs the listed command before dictation
will work. If the global hotkey is blocked, log out and back in after adding
yourself to the input group so the new group membership takes effect.
MSG
