# Releasing Whisper Smart

One tag ships both platforms. `vX.Y.Z` carries the macOS DMG and the Linux
tarball, built from the same commit by
[`.github/workflows/release.yml`](../.github/workflows/release.yml).

```
params ──┬── macos   release gate → signed + notarized DMG → appcast entry ──┬── publish
         └── linux   QA smoke → versioned tarball → version check ──────────┘
```

`params` resolves the version, channel, changelog range **and commit SHA**
once. Every later job checks out that SHA rather than a branch name, so a merge
landing on `main` mid-run cannot give the two platform builds different source,
or tag artifacts as containing work that was not in them.

They run in parallel and **both must pass** before `publish` does anything: the
appcast commit, the version bump, the tag and the GitHub Release are all
created in that last job. A failed build on either platform leaves no tag, no
release, and no half-updated appcast behind.

`publish` tags the commit it built, pushes the tag, and only then updates
`main`. If `main` moved during the build, the release bookkeeping is replayed
on top of it with a cherry-pick — the tag keeps describing its own artifacts
either way.

## Cutting a release

**Automatic** — merging a PR into `main` cuts a beta release with an
auto-bumped patch version.

| Want | Do |
|---|---|
| Patch bump (default) | Merge the PR |
| Minor / major bump | Label the PR `release:minor` / `release:major` |
| No release | Label the PR `skip-release` |

Docs-, site- and CI-only PRs never trigger one (see `paths-ignore` in the
workflow).

**Manual** — for an explicit version, a written summary, or the production
channel:

```bash
gh workflow run release.yml \
  -f version=0.5.0 \
  -f channel=beta \
  -f checklist_confirmed=true \
  -f notes="What this release is about."
```

Preview the notes the run will publish, before running it:

```bash
bash scripts/compose_release_notes.sh --version 0.5.0 --channel beta
```

## What each version number touches

`params` picks the version; everything else follows it, so there is nothing to
bump by hand:

| Where | How |
|---|---|
| macOS app bundle | `VERSION` env → `scripts/build_release_app.sh` |
| Linux binary (`CARGO_PKG_VERSION`) | `linux/packaging/set-version.sh` → `linux/Cargo.toml` + `Cargo.lock` |
| Both PKGBUILDs (`pkgver`) | same script |
| AUR checksum (`sha256sums`) | computed from the tag tarball after the tag is pushed |
| `appcast.xml` | `scripts/update_appcast.sh`, signed with `SPARKLE_PRIVATE_KEY` |

The Linux job asserts the built binary reports the release version before the
artifact is allowed out, so a missed stamp fails the run rather than shipping a
mislabelled tarball.

## Release notes

`scripts/compose_release_notes.sh` writes them once and both consumers reuse it:

- the **GitHub Release** body — summary, changelog since the previous tag, and
  a download table with the install command for each platform;
- the **Sparkle appcast** entry (`--format appcast`) — the same summary and
  changelog without the download table, since Sparkle is already downloading
  the DMG it describes.

The changelog is the commit subjects since the previous tag, with the release
bookkeeping commits filtered out.

## Artifacts on every release

| Platform | Asset | Notes |
|---|---|---|
| macOS 14+ | `Whisper-Smart-mac.dmg` | Developer ID signed and notarized; ad-hoc signing is never published |
| macOS | `appcast.xml` | Sparkle feed, also committed to `main` and mirrored to `master` for legacy clients |
| Linux x86_64 | `whisper-smart-<version>-linux-x86_64.tar.gz` | Built on Arch against GTK 4; relocatable, carries its own `install.sh` |
| Linux | `…tar.gz.sha256` | Checksum for the tarball |

## Secrets the workflow needs

| Secret | Used for |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | Code signing (all channels) |
| `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` | Notarization (mandatory for Developer ID builds) |
| `SPARKLE_PRIVATE_KEY` | Signing the appcast entry |

The Linux job needs no secrets.

## Before a production release

Run through [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), then dispatch with
`checklist_confirmed=true`. The workflow refuses to start without it.

## Building the same artifacts locally

```bash
# macOS
VERSION=X.Y.Z ALLOW_ADHOC_SIGNING=1 bash scripts/package_dmg.sh

# Linux
cd linux
bash packaging/set-version.sh X.Y.Z
VERSION=X.Y.Z bash packaging/make-tarball.sh
```

Local DMGs are ad-hoc signed and are for testing only — Gatekeeper blocks them
on another Mac, and they are never what a release ships.

The macOS bundle step takes overrides for one-off builds:

```bash
APP_NAME="Whisper Smart" \
BUNDLE_ID="com.whispersmart.desktop" \
VERSION="0.5.0" \
BUILD_NUMBER="20260830" \
LOGO_PATH="$(pwd)/logo.png" \
bash scripts/build_release_app.sh
```

`BUNDLE_ID` is the one thing not to change: `build_release_app.sh` refuses to
build with a different identifier, because changing it resets every macOS TCC
permission grant users have already given the app.

Verify a local DMG by mounting it — `open .build/release/Whisper-Smart-mac.dmg`
should show `Whisper Smart.app` beside an `Applications` symlink. Linux
tarballs unpack to a directory with `install.sh`, which installs under
`~/.local` and needs no root.

## Prerequisites for a local build

- **macOS**: Xcode Command Line Tools (`xcode-select --install`); `swiftc`,
  `sips`, `iconutil` and `hdiutil` on PATH.
- **Linux**: Rust 1.85+, `pkgconf`, and the GTK 4 stack (`gtk4`,
  `gtk4-layer-shell`, `alsa-lib`, `libpulse`).
