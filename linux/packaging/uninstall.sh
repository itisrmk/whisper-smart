#!/usr/bin/env bash
# Removes a user-prefix install. Model weights and settings are kept unless
# --purge is passed, because re-downloading several gigabytes by accident is a
# worse outcome than leaving a directory behind.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

systemctl --user disable --now whisper-smart 2>/dev/null || true
rm -f "$PREFIX/bin/whisper-smart"
rm -rf "$PREFIX/lib/whisper-smart"
rm -f "$PREFIX/share/applications/whisper-smart.desktop"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/whisper-smart.service"
systemctl --user daemon-reload 2>/dev/null || true

if (( PURGE )); then
    rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/whisper-smart"
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/whisper-smart"
    rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/whisper-smart"
    rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/whisper-smart"
    echo "Removed Whisper Smart, its settings, and its downloaded models."
else
    echo "Removed Whisper Smart. Settings and models kept; pass --purge to delete them."
fi
