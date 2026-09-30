#!/usr/bin/env bash
# Stamps a release version onto the Windows build.
#
# Mirrors linux/packaging/set-version.sh: a Rust binary carries
# CARGO_PKG_VERSION compiled into it, so `whisper-smart --version` only
# matches the tag if the manifest is updated before the build. The release
# workflow runs this first, then commits the result alongside the appcast.
#
#   bash windows/packaging/set-version.sh 0.5.0
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <major.minor.patch>" >&2
    exit 1
fi

WINDOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WINDOWS_DIR"

# Only the [package] version at the top of the manifest, never a dependency's.
awk -v version="$VERSION" '
    /^\[/ { section = $0 }
    section == "[package]" && /^version *= *"/ {
        print "version = \"" version "\""
        next
    }
    { print }
' Cargo.toml > Cargo.toml.tmp && mv Cargo.toml.tmp Cargo.toml

# `cargo build --locked` in CI rejects a lockfile that disagrees with the
# manifest, so the package's own entry moves with it.
awk -v version="$VERSION" '
    /^name = "whisper-smart"$/ { print; getline; sub(/^version = ".*"$/, "version = \"" version "\""); print; next }
    { print }
' Cargo.lock > Cargo.lock.tmp && mv Cargo.lock.tmp Cargo.lock

echo "Windows version set to ${VERSION}"
grep -m1 '^version' Cargo.toml
