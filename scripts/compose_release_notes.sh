#!/usr/bin/env bash
# Composes the release notes for one version, for both platforms.
#
# A release is a single tag carrying a macOS DMG and a Linux tarball, so the
# notes are written once here and reused everywhere: the GitHub Release body,
# the Sparkle appcast entry, and a local dry run before tagging anything.
#
#   bash scripts/compose_release_notes.sh --version 0.5.0 --channel beta
#
# --format release  (default) full notes: summary, changelog, downloads
# --format appcast            what Sparkle shows in the updater window; the
#                             download table is dropped because Sparkle is
#                             already downloading the DMG it describes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION=""
CHANNEL="beta"
PREVIOUS_TAG=""
SUMMARY=""
FORMAT="release"
REPOSITORY="${GITHUB_REPOSITORY:-itisrmk/whisper-smart}"

usage() {
    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        --previous-tag) PREVIOUS_TAG="${2:-}"; shift 2 ;;
        --notes) SUMMARY="${2:-}"; shift 2 ;;
        --repository) REPOSITORY="${2:-}"; shift 2 ;;
        --format) FORMAT="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "Missing --version" >&2
    exit 1
fi
case "$FORMAT" in
    release|appcast) ;;
    *) echo "Unknown --format '$FORMAT' (expected release or appcast)" >&2; exit 1 ;;
esac

TAG="v${VERSION}"
if [[ -z "$PREVIOUS_TAG" ]]; then
    PREVIOUS_TAG="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -v "^${TAG}$" | head -n 1 || true)"
fi

# The changelog is the commits since the previous tag, minus the bookkeeping
# the release itself pushes — an appcast bump tells a user nothing.
changelog() {
    local range="HEAD"
    [[ -n "$PREVIOUS_TAG" ]] && range="${PREVIOUS_TAG}..HEAD"
    git log --no-merges --pretty=format:'%s' "$range" 2>/dev/null |
        grep -vE '^chore\(release\):' |
        grep -vE '^(Merge |Bump appcast)' |
        sed 's/^/- /' || true
}

CHANGES="$(changelog)"

if [[ -n "$SUMMARY" ]]; then
    printf '%s\n\n' "$SUMMARY"
fi

if [[ -n "$CHANGES" ]]; then
    printf '### Changes\n\n%s\n\n' "$CHANGES"
elif [[ -z "$SUMMARY" ]]; then
    printf 'Whisper Smart %s.\n\n' "$VERSION"
fi

if [[ "$FORMAT" == "appcast" ]]; then
    exit 0
fi

LINUX_TARBALL="whisper-smart-${VERSION}-linux-x86_64.tar.gz"
DOWNLOAD_BASE="https://github.com/${REPOSITORY}/releases/download/${TAG}"

cat <<EOF
### Downloads

| Platform | Artifact | Install |
|---|---|---|
| macOS 14+ | [Whisper-Smart-mac.dmg](${DOWNLOAD_BASE}/Whisper-Smart-mac.dmg) | Open the DMG, drag the app to Applications |
| Linux (x86_64) | [${LINUX_TARBALL}](${DOWNLOAD_BASE}/${LINUX_TARBALL}) | \`tar xzf ${LINUX_TARBALL} && ./whisper-smart-${VERSION}-linux-x86_64/install.sh\` |

Existing macOS installs update themselves through Sparkle. On Arch, \`whisper-smart\`
from the AUR tracks this tag.

Release channel: **${CHANNEL}**
EOF

if [[ -n "$PREVIOUS_TAG" ]]; then
    printf 'Rollback: https://github.com/%s/releases/tag/%s\n' "$REPOSITORY" "$PREVIOUS_TAG"
else
    printf 'Rollback: none (first tagged release).\n'
fi
