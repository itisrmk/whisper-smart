# Phase 5 QA Hardening + Release Readiness

_Date: 2026-02-11_

This document defines practical QA execution artifacts for Phase 5:
1. deterministic smoke checks,
2. manual app compatibility matrix,
3. lightweight performance/battery observations,
4. release pass/fail gate.

---

## 1) Deterministic Smoke Suite

### Command
```bash
bash scripts/run_qa_smoke.sh
```

### Scope
- `DictationStateMachine` lifecycle smoke:
  - `idle -> recording -> transcribing -> success -> idle`
  - transcript post-processing still applied before injection
  - stale provider callbacks ignored after `replaceProvider`
- `STTProviderResolver` diagnostics smoke:
  - OpenAI provider falls back to Apple when cloud opt-in is disabled
  - fallback diagnostics include `fallbackReason`
  - OpenAI remains selected when cloud opt-in + API key are present

### Files
- `tests/smoke/qa_smoke.swift`
- `scripts/run_qa_smoke.sh`

---

## 2) Manual App Compatibility Checklist + Report Template

Run this matrix against a build candidate and keep one report per run.

### Test preconditions
- Accessibility, Microphone, and Speech Recognition permissions granted.
- Provider selected: Apple Speech first pass, then Parakeet pass.
- Insertion mode tested in:
  - Smart (AX then Paste)
  - Accessibility Only
  - Pasteboard Only
- Use a fixed spoken sample for consistency:
  - Sample A: `"hello world this is a dictation smoke test"`
  - Sample B: `"new paragraph bullet one bullet two"`

### Compatibility Matrix

| App | Scenario | Expected | Pass/Fail | Notes / Failure Signature |
|---|---|---|---|---|
| Apple Mail | New compose body | Text inserted at caret, no duplicate paste, no clipboard loss |  |  |
| Slack (desktop) | Channel message box | Text inserted at caret, no accidental send |  |  |
| Notion | Page paragraph block | Text inserted in active block, no focus drop |  |  |
| Google Docs (browser) | Document body | Text inserted where caret is, no IME/cursor jump |  |  |
| VS Code | Editor file buffer | Text inserted at cursor, undo stack behaves normally |  |  |
| Cursor | Editor file buffer | Text inserted at cursor, no command palette interference |  |  |
| Terminal (macOS Terminal + iTerm if available) | Shell prompt | Text inserted at prompt, no control character artifacts |  |  |

### Per-app checklist
- [ ] Hold-to-record starts reliably (or one-shot if explicitly used).
- [ ] Release ends recording and transitions to transcribing.
- [ ] Final text appears once (no duplicate insertion).
- [ ] Clipboard restores correctly after paste fallback.
- [ ] Error state is actionable when insertion fails.

### Report template

```markdown
# Manual Compatibility Report
Date/Time:
Build/Commit:
macOS Version:
Machine:
Provider:
Insertion Mode:

## Summary
- Total scenarios:
- Passed:
- Failed:
- Blockers:

## Detailed Results
| App | Scenario | Result | Notes | Screenshot/Log Ref |
|---|---|---|---|---|
| Mail | Compose body | PASS |  |  |

## Failure Details
### <App/Scenario>
- Steps:
- Actual behavior:
- Expected behavior:
- Repro frequency:
- Workaround:
- Suspected layer (Hotkey / Audio / STT / Injector / UI):
```

---

## 3) Lightweight Performance + Battery Checklist

Goal: establish baseline behavior for idle, recording, transcribing states without heavyweight profiling infrastructure.

### Instrumentation already available
- Bubble activity badge shows:
  - `REC` while recording
  - `STT` while transcribing
  - `<N>ms` after success (transcribe latency)
- Unified logs include state transitions and provider diagnostics.

### Observation procedure (single machine baseline)
1. Start app and leave idle for 5 minutes.
2. Run 10 dictation cycles (~5s speech each) in target app.
3. Include both Apple Speech and Parakeet runs.
4. Record readings from Activity Monitor (CPU %, Energy Impact) at each phase.

### Checklist
- [ ] Idle CPU remains low/stable (no runaway growth over 5 min).
- [ ] Recording starts within acceptable UX threshold (target <= 300ms perceived).
- [ ] Transcribe completion latency generally consistent (badge ms + subjective).
- [ ] No sustained high-energy usage after returning to idle.
- [ ] No memory climb trend across 10 cycles.

### Performance report template

```markdown
# Performance/Battery Observation Report
Date/Time:
Build/Commit:
Provider:
Machine/macOS:

## Measurements
| Phase | Sample Size | CPU % (range) | Energy Impact (range) | Notes |
|---|---:|---|---|---|
| Idle (5 min) |  |  |  |  |
| Recording |  |  |  |  |
| Transcribing |  |  |  |  |

## Latency
- Median transcribe latency (badge ms):
- P95 transcribe latency (badge ms):
- Worst observed latency:

## Regressions / Anomalies
- 

## Verdict
- [ ] Meets baseline
- [ ] Needs optimization before release
```

---

## 4) Release Readiness Checklist (Pass/Fail Gate)

A release candidate is **GO** only if all blockers pass.

### Blockers (must pass)
- [ ] `bash scripts/typecheck.sh` passes.
- [ ] `bash scripts/run_qa_smoke.sh` passes.
- [ ] Manual compatibility matrix: no blocker failures in Mail, Slack, Notion, Google Docs, VS Code/Cursor, Terminal.
- [ ] No critical permission-flow regressions (hotkey + mic + speech usable after setup).
- [ ] No crash/hang during 10-cycle dictation stress pass.

### Non-blocking quality checks (should pass; may ship with tracked follow-up)
- [ ] Performance/battery report collected for current candidate.
- [ ] Known fallback behavior (provider diagnostics + user messaging) validated.
- [ ] Documentation updated for any behavior changes in this candidate.

### Final release decision template

```markdown
# Release Readiness Decision
Build/Commit:
Date:
Owner:

## Blocker Status
- Typecheck: PASS/FAIL
- QA Smoke: PASS/FAIL
- Compatibility Matrix: PASS/FAIL
- Permission Flow: PASS/FAIL
- 10-cycle Stability: PASS/FAIL

## Decision
- [ ] GO
- [ ] NO-GO

## If NO-GO, required fixes
1.
2.
```
