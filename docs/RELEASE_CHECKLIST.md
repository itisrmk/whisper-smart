# Release Checklist

Use this checklist before triggering `.github/workflows/release-dmg.yml`.

## QA Gates
- [ ] `bash scripts/typecheck.sh` passed.
- [ ] `bash scripts/run_qa_smoke.sh` passed.
- [ ] `bash scripts/run_visual_regression.sh` passed.
- [ ] `bash scripts/release_gate.sh` passed.

## Product Checks
- [ ] Parakeet local model setup verified on clean machine flow.
- [ ] Cloud provider key save + transcription path verified.
- [ ] Settings UI reviewed for regressions in General / Hotkey / Provider / History tabs.
- [ ] Compatibility sweep report generated (`scripts/run_app_compatibility_matrix.sh`).

## Release Checks
- [ ] Version number selected.
- [ ] Release notes prepared.
- [ ] Rollback release tag identified.
- [ ] If `production` channel: signing + notarization secrets are available.

## Approval
- [ ] `checklist_confirmed=true` set in workflow dispatch.
