#!/usr/bin/env bash
# Builds the release tarball published alongside the macOS DMG.
#
# The tarball is deliberately relocatable: it carries a small install script
# that drops everything under a prefix (~/.local by default), so a user can
# unpack and install without root and without a package manager. Distro
# packages (see packaging/aur) remain the better route on Arch.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

VERSION="${VERSION:-$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)}"
ARCH="${ARCH:-$(uname -m)}"
NAME="whisper-smart-${VERSION}-linux-${ARCH}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/dist}"
STAGE="$OUT_DIR/$NAME"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    say "Building release binary"
    cargo build --release --locked
fi

BINARY="$REPO_DIR/target/release/whisper-smart"
[[ -x "$BINARY" ]] || { echo "No binary at $BINARY (build first, or unset SKIP_BUILD)" >&2; exit 1; }

say "Staging $NAME"
rm -rf "$STAGE"
install -Dm755 "$BINARY" "$STAGE/bin/whisper-smart"
install -Dm644 "$REPO_DIR/python/stt_daemon.py" "$STAGE/lib/whisper-smart/stt_daemon.py"
install -Dm644 "$REPO_DIR/packaging/whisper-smart.desktop" "$STAGE/share/applications/whisper-smart.desktop"
install -Dm644 "$REPO_DIR/packaging/whisper-smart.service" "$STAGE/share/whisper-smart/whisper-smart.service"
install -Dm644 "$REPO_DIR/resources/whisper-smart-logo.png" \
    "$STAGE/share/icons/hicolor/512x512/apps/whisper-smart.png"
install -Dm644 "$REPO_DIR/README.md" "$STAGE/README.md"

# The installer that ships *inside* the tarball. It only moves files around, so
# it stays independent of the repo it was built from.
cat > "$STAGE/install.sh" <<'INNER'
#!/usr/bin/env bash
# Installs Whisper Smart from this tarball. No root required.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"

install -Dm755 "$HERE/bin/whisper-smart"                    "$PREFIX/bin/whisper-smart"
install -Dm644 "$HERE/lib/whisper-smart/stt_daemon.py"      "$PREFIX/lib/whisper-smart/stt_daemon.py"
install -Dm644 "$HERE/share/applications/whisper-smart.desktop" \
                                                            "$PREFIX/share/applications/whisper-smart.desktop"
install -Dm644 "$HERE/share/icons/hicolor/512x512/apps/whisper-smart.png" \
                                                            "$PREFIX/share/icons/hicolor/512x512/apps/whisper-smart.png"

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
install -d "$UNIT_DIR"
sed "s|^ExecStart=.*|ExecStart=$PREFIX/bin/whisper-smart|" \
    "$HERE/share/whisper-smart/whisper-smart.service" > "$UNIT_DIR/whisper-smart.service"
systemctl --user daemon-reload 2>/dev/null || true

echo
echo "Installed to $PREFIX."
command -v whisper-smart >/dev/null 2>&1 || \
    echo "Note: $PREFIX/bin is not on your PATH — add it to your shell profile."
echo
"$PREFIX/bin/whisper-smart" --check || true
cat <<MSG

  Start now:        systemctl --user start whisper-smart
  Start at login:   systemctl --user enable --now whisper-smart
  Uninstall:        rm -rf "$PREFIX/bin/whisper-smart" "$PREFIX/lib/whisper-smart"

Anything reported FAIL above needs the listed command before dictation works.
MSG
INNER
chmod 755 "$STAGE/install.sh"

say "Compressing"
mkdir -p "$OUT_DIR"
tar -C "$OUT_DIR" -czf "$OUT_DIR/$NAME.tar.gz" "$NAME"
( cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
rm -rf "$STAGE"

say "Built $OUT_DIR/$NAME.tar.gz"
du -h "$OUT_DIR/$NAME.tar.gz"
cat "$OUT_DIR/$NAME.tar.gz.sha256"
