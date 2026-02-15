# 5-Phase Execution Roadmap (Kickoff)

Date: 2026-02-15  
Scope: macOS app (`Whisper Smart`)  
Status: **Completed**

## Delivery Cadence
- Weekly planning and health review.
- Daily release-gate run before merging to `main`.
- Every phase has measurable exit criteria.

## Phase 1 — Stability + UX Lock
Objective: Remove UI regressions and lock interaction quality.

Started:
- Sidebar-first settings redesign shipped.
- Settings shell migrated to native SwiftUI scroll container with hidden indicators.
- Selection chrome updated to remove bright-blue active outline while preserving clear active state.
- QA gate script added for repeatable checks.
- Added screenshot-based visual regression harness for settings tabs (`scripts/run_visual_regression.sh`).
- Added compatibility sweep artifact generator for core app matrix (`scripts/run_app_compatibility_matrix.sh`).

Completed:
- Screenshot regression checks run in CI + release gate.
- Compatibility matrix report generation integrated into release gate.
- Settings UI regressions for scroll/focus chrome closed.

Exit Criteria:
- No known P0/P1 UI regressions.
- Release gate green on 3 consecutive runs.

## Phase 2 — Parakeet Reliability + Performance
Objective: Improve first-run and repeated-session local performance.

Started:
- Session-level metrics store added (`dictation-sessions.json`) with p95/avg summary support.
- App now records per-session recording/transcribing/end-to-end durations with provider/app context.
- History tab now surfaces Avg/P95 end-to-end latency and SLO status chips.
- Added provider-aware latency QA report script with SLO enforcement path (`scripts/qa_latency_report.sh`).

Completed:
- Defined provider SLO targets (Apple/Parakeet/Whisper/OpenAI buckets).
- Enforced SLOs in QA report when sufficient samples are present.

Exit Criteria:
- First-run provisioning reliability target hit.
- p50/p95 latency reduced versus baseline.

## Phase 3 — Cloud Hardening
Objective: Make cloud setup robust and predictable.

Started:
- OpenAI API key validation model added (`empty`, `valid`, `suspicious`, `malformed`).
- Provider settings now surfaces validation-driven status messaging after save.
- OpenAI API key persistence moved to Keychain-backed storage with legacy migration + fallback path.
- Smoke tests updated for normalized persistence and malformed-key validation.
- Added endpoint profile support (official + compatible gateway) with URL/model validation.

Completed:
- Cloud endpoint profile + model are configurable and validated in UI.
- Provider diagnostics now checks endpoint validity and surfaces fallback reason.

Exit Criteria:
- >99% cloud setup success in QA matrix.
- No “saved key but unusable” regressions.

## Phase 4 — Dictation Quality + Workflow
Objective: Improve output quality while keeping UX simple.

Started:
- Added global default writing style setting (`neutral/formal/casual/concise/developer`).
- App style processor now applies global style fallback when no per-app profile is present.
- Added domain presets (`general/email/support/coding/notes`) with style mapping.
- Added smoke coverage for domain preset fallback behavior.
- Added guided per-app recommendation chips for quick profile setup.
- Expanded style transform smoke coverage for formal/domain behavior.

Completed:
- Domain presets wired to effective style processor behavior.
- Quality smoke coverage expanded (concise/formal/developer domain paths).
- Guided per-app recommendations shipped in settings.

Exit Criteria:
- Measured transcript quality uplift on benchmark phrases.
- Domain presets validated by QA scripts and manual app matrix.

## Phase 5 — Release + Ops Maturity
Objective: Standardize CI/CD and release quality gates.

Started:
- Added CI workflow: `.github/workflows/macos-ci.yml`.
- Added manual release workflow with DMG asset publishing: `.github/workflows/release-dmg.yml`.
- Added release gate script: `scripts/release_gate.sh`.
- Release workflow now runs full release gate, captures rollback reference, and publishes generated notes.
- Release gate now verifies DMG artifact presence and SHA-256 checksum.
- Added release checklist doc + explicit workflow checklist confirmation gate.
- Added production channel signing and notarization stages in release workflow.

Completed:
- Release checklist is enforced before tag creation via workflow input gate.
- Production release path imports Developer ID cert, signs app, notarizes/staples DMG.

Exit Criteria:
- One-command release candidate validation.
- Automated tag + DMG release flow stable for 3 releases.

## KPI Board
- First-run setup success rate.
- Dictation success rate (inserted/error).
- p50/p95 end-to-end latency by provider.
- Crash-free sessions.
- Cloud key validation failure rate.
