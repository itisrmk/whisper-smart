#!/usr/bin/env bash
# Stamps a release version onto the Linux build.
#
# macOS takes its version from the release workflow's VERSION at package time,
# but a Rust binary carries CARGO_PKG_VERSION compiled into it, so `whisper-smart
# --version` only matches the tag if the manifest is updated before the build.
# The release workflow runs this first, then commits the result alongside the
# appcast, which keeps the repo, the tag, and both binaries on one version.
#
#   bash linux/packaging/set-version.sh 0.5.0
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <major.minor.patch>" >&2
    exit 1
fi

LINUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LINUX_DIR"

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

# The AUR package builds from the tag, so its pkgver tracks the same number.
# updpkgsums fills in the checksum once the tag tarball exists (see the publish
# step of the release workflow).
for pkgbuild in packaging/PKGBUILD packaging/aur/whisper-smart/PKGBUILD; do
    [[ -f "$pkgbuild" ]] || continue
    sed -i -E "s/^pkgver=.*/pkgver=${VERSION}/" "$pkgbuild"
done

echo "Linux version set to ${VERSION}"
grep -m1 '^version' Cargo.toml
