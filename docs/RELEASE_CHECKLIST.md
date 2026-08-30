# Release Checklist

Use this before dispatching [`.github/workflows/release.yml`](../.github/workflows/release.yml)
by hand. See [RELEASE.md](RELEASE.md) for how the pipeline works.

Automatic beta releases (merged PRs) rely on CI having run both platform jobs
on the PR; this checklist is for manual and production releases.

## QA Gates — macOS
- [ ] `bash scripts/typecheck.sh` passed.
- [ ] `bash scripts/run_qa_smoke.sh` passed.
- [ ] `bash scripts/run_visual_regression.sh` passed.
- [ ] `bash scripts/release_gate.sh` passed.

## QA Gates — Linux
- [ ] `cd linux && bash scripts/run_qa_smoke.sh` passed (fmt, clippy, tests, sidecar).
- [ ] `./target/release/whisper-smart --check` reports no failures on a real desktop.
- [ ] Dictation verified end to end on Wayland: hotkey → transcript at the cursor.

## Product Checks
- [ ] Local model setup verified on a clean machine flow (MLX on macOS, whisper.cpp on Linux).
- [ ] Cloud provider key save + transcription path verified.
- [ ] Settings reviewed for regressions across General / Hotkey / Provider / History.
- [ ] Compatibility sweep report generated (`scripts/run_app_compatibility_matrix.sh`).

## Release Checks
- [ ] Version number selected (one number, both platforms).
- [ ] Release notes previewed: `bash scripts/compose_release_notes.sh --version X.Y.Z`.
- [ ] Rollback release tag identified.
- [ ] Signing certificate secrets are available (all channels).
- [ ] If `production` channel: notarization secrets are available.
- [ ] Release artifact is Developer ID signed (not ad-hoc) to preserve macOS permission continuity across updates.

## Approval
- [ ] `checklist_confirmed=true` set in the workflow dispatch.

## After the run
- [ ] Release shows all four assets: DMG, appcast, Linux tarball, tarball checksum.
- [ ] Sparkle update offered to an existing macOS install.
- [ ] AUR `whisper-smart` pushed with the synced `pkgver` and `sha256sums` (see `linux/packaging/aur/README.md`).
