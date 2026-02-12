# Performance + Provider Expansion Plan (3-Role Workflow)

Date: 2026-02-11
Owner: VisperflowClone team
Execution mode: Orchestrator + Implementer + Independent Verifier

## Goals

1. Make local Parakeet feel faster (latency + responsiveness).
2. Add second local provider option (Open-source Whisper local).
3. Keep provider UX simple: Cloud + Local options without technical clutter.
4. Preserve reliability with measurable verification at each phase.

---

## Baseline / Observability First

Before optimization, capture baseline timings:
- T1: hotkey hold end -> transcribing state start
- T2: transcribing start -> first partial/final text
- T3: final text -> injection complete
- Session success/failure counts by provider

Deliverables:
- Structured timing logs (provider name + ms)
- Lightweight summary line in logs for each session

Acceptance:
- Can compare before/after with real numbers (p50/p95)

---

## Phase 1 — Fast Wins for Parakeet Latency

### 1. Runtime/model warmup
- Pre-warm Parakeet runtime in background after app launch.
- Cache successful runtime/model validation result.
- Avoid repeated expensive checks every session.

### 2. Session path cleanup
- Ensure no provider replacement races during active dictation lifecycle.
- Keep provider instance stable from beginSession -> endSession.

### 3. Audio/inference path tuning
- Keep capture conversion path minimal and deterministic.
- Reduce unnecessary allocations/copies where safe.

Acceptance:
- Lower first-run latency and repeat-run latency.
- No transcribing stalls introduced.

---

## Phase 2 — Streaming/Perceived Speed Improvements

### 1. Partial-result UX
- Show partial transcript quickly during transcribing (already scaffolded; tune frequency/latency).

### 2. Smarter auto-stop
- Improve endpointing behavior (silence + speech-tail heuristics).

### 3. Timeout policy tuning
- Keep provider-specific timeout thresholds, with clear user-facing errors.

Acceptance:
- Faster perceived response after releasing shortcut.
- Stable behavior under short and long dictation samples.

---

## Phase 3 — Add Whisper Local (Open-source) as Second Local Option

Target providers:
- Cloud: OpenAI Whisper API
- Local: NVIDIA Parakeet
- Local: Whisper Local (open-source runtime)

Implementation:
- Wire Whisper Local provider path as selectable production option.
- Capability checks (runtime/model present).
- Friendly setup UX (download/install paths hidden unless advanced view).

Acceptance:
- User can switch among Cloud / Local Parakeet / Local Whisper.
- Each provider has clear readiness state and error messages.

---

## Phase 4 — Provider UX Refresh (Simple Product UI)

Design direction:
- Speech to Text section with clear cards:
  - OpenAI Cloud
  - NVIDIA Parakeet Local
  - Whisper Local
- Keep advanced controls behind optional “Advanced” expander.
- Remove source/tokenizer URL noise from default view.

Acceptance:
- Non-technical user can configure provider in <30 seconds.

---

## Verification Matrix (Independent Verifier)

For every phase:
1. `bash scripts/typecheck.sh`
2. `swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" -o VisperflowClone app/**/*.swift`
3. Manual smoke:
   - Start/stop dictation via hotkey
   - Start/stop via menu
   - Insert text in focused editor
   - Provider switch while idle
4. Log review:
   - No unexpected provider replacement during active session
   - No stuck transcribing without timeout/error

---

## Execution Order (Immediate)

1. Add timing instrumentation + baseline metrics (today).
2. Add warmup + validation caching for Parakeet (today).
3. Tune endpointing/timeouts with measured deltas (next).
4. Ship Whisper Local selectable option + simple provider cards (next).
5. Final QA pass + docs update.

---

## Notes

- IMK/TIProperty logs are benign macOS input-method noise; do not treat as root cause.
- Keep default UX minimal and fast.
- Preserve fallback clarity in UI/logs without silent behavior changes.
