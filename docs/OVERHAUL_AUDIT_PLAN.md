# VisperflowClone Overhaul Audit + Action Plan

_Date: 2026-02-11_

## 1) Executive Audit Summary

VisperflowClone has a **solid modular spine** (Hotkey → Audio → STT Provider → Injector orchestrated by `DictationStateMachine`) and currently type-checks cleanly. The app is beyond MVP prototype: Apple Speech and local Parakeet pipelines are wired, with runtime diagnostics and model download UX.

However, reliability and product parity are held back by four classes of gaps:

1. **Control-flow correctness gaps** (menu toggles/record lifecycle semantics, stale error handling edge cases).
2. **Reliability gaps** in hotkey capture, audio interruption/device-change resilience, and paste insertion safety.
3. **UX parity gaps vs Wispr-style experience** (no live transcript overlay, minimal feedback loop, no command/cleanup pipeline).
4. **Spec/docs drift** (legacy docs still describe stub-first flow and outdated provider status).

---

## 2) Current Architecture Map (as implemented)

## App layer
- `app/App/main.swift` boots AppKit app.
- `app/App/AppDelegate.swift` owns all controllers/services and wires callbacks.

## UI layer
- `MenuBarController` — status icon + controls + diagnostics lines.
- `BubblePanelController` + `FloatingBubbleView` — floating state bubble.
- `SettingsWindowController` + `SettingsView` — General/Hotkey/Provider tabs.
- `BubbleStateSubject` — UI state bridge (`state`, `audioLevel`, `errorDetail`).

## Core layer
- Input: `HotkeyMonitor` + persisted `HotkeyBinding`.
- Audio: `AudioCaptureService` (`AVAudioEngine` + converter to 16k mono float).
- STT abstraction: `STTProvider` protocol.
- Implemented providers:
  - `AppleSpeechSTTProvider` (real, partial+final callbacks).
  - `ParakeetSTTProvider` (real local ONNX via Python runner).
  - `StubSTTProvider` (test-only, intentionally errors).
- Provider orchestration:
  - `STTProviderKind`, `STTProviderResolver`, runtime diagnostics store.
- Local model/runtime infra:
  - `ModelDownloaderService`, `ModelDownloadState`.
  - `ParakeetRuntimeBootstrapManager`.
  - `ParakeetModelSourceConfiguration`.
- Orchestration:
  - `DictationStateMachine` governs idle/recording/transcribing/error.
- Output:
  - `ClipboardInjector` (pasteboard + Cmd+V, key-events fallback unimplemented).

## Script runtime
- `scripts/parakeet_infer.py`: robust check/infer path with onnx-asr preferred path and raw ONNX fallback.

---

## 3) Observed Breakages / Fragile Behavior

## A. Control-flow / UX behavior mismatches
1. **Menu “Start Dictation” action is semantically incorrect**
   - In `AppDelegate`, menu toggle calls `stateMachine.activate()`/`deactivate()`.
   - `activate()` only starts hotkey monitoring; it does not start recording.
   - Outcome: user-facing label implies immediate dictation but does not do so.

2. **No explicit success surface in lifecycle**
   - `BubbleState.success` exists but state machine goes directly to `.idle` after final result.
   - UX misses completion confirmation pulse used by Wispr-like flows.

3. **Error recovery complexity / repeated provider replacement**
   - Provider refresh path can call replacement twice in some branches.
   - Not compile-broken, but raises maintainability and state-coherence risk.

## B. Audio/visual feedback gaps affecting perceived reliability
4. **Waveform UI is not fed by live audio amplitude**
   - `BubbleStateSubject.updateAudioLevel` exists but is never called from pipeline.
   - Listening waveform therefore appears mostly decorative, not responsive.

5. **Partial STT results not surfaced**
   - State machine explicitly TODOs partial result overlay.
   - Apple Speech can emit partials, but user sees only state labels.

## C. Insertion robustness risks
6. **Clipboard restoration is string-only and time-based**
   - Restores only plain text after fixed delay (0.2s).
   - Risks clobbering non-string/RTF clipboard content and races under load.

7. **No AX direct insertion path yet**
   - Current injector is paste simulation only; broad but less deterministic.
   - Rich editors/web apps can be flaky with command-paste timing.

## D. Runtime reliability gaps
8. **No explicit audio interruption/device-change handling**
   - TODO remains for CoreAudio device change listener.
   - Mic hot-swap/interruption recovery may require manual retry.

9. **Global permission request bundle is aggressive**
   - App requests Speech permission at startup regardless of provider path.
   - Increases onboarding friction and can degrade trust.

## E. Spec/documentation drift
10. **Runbook and architecture docs are stale**
   - `docs/PROTOTYPE_RUNBOOK.md` still references stub transcript behavior.
   - `docs/ARCHITECTURE.md` lists Apple Speech as TODO though implemented.

---

## 4) STT Pipeline Status (Ground Truth)

## Implemented now
- **Apple Speech**: operational provider with partial/final callbacks and permission gating.
- **Parakeet local ONNX**: operational path with model source config, download/validation, runtime bootstrap, and Python runner.
- **Dynamic provider resolution** with diagnostics and fallback to Apple Speech.

## Partially implemented
- Provider diagnostics are strong, but user-facing recovery/flows are still complex.
- Partials generated by provider are not consumed by UI.

## Not implemented yet
- **Whisper local provider runtime** (kind exists, diagnostics mark unavailable).
- **OpenAI Whisper API provider** (kind exists, diagnostics mark unavailable).

---

## 5) Hotkey/Capture/Paste Reliability Gap Audit

## Hotkey
- Strengths: configurable bindings, modifier-only + combo support, event tap auto re-enable.
- Gaps:
  - Event-tap dependency remains brittle in unsigned/dev flows.
  - No conflict detection with other global shortcuts.
  - Menu start/stop semantics do not match dictation intent.

## Capture
- Strengths: format mismatch crash guarded via converter; permission checks in place.
- Gaps:
  - no device-change listener
  - no interruption strategy
  - no VAD/noise gating or level feed to UI

## Paste/Injection
- Strengths: universal fallback likely works in most apps.
- Gaps:
  - no AX native insertion path
  - clipboard round-trip may lose metadata and race
  - no per-app insertion strategy heuristics

---

## 6) UI Gaps vs Wispr-style Reference

Compared with Wispr-like “hold-talk-release” polish, current UI is still shell-level:

1. **No live transcript overlay text** (only icon/label state).
2. **No inline partial-to-final transition** while recording/transcribing.
3. **No confidence/error contextual hints near cursor** (only bubble/menu diagnostics).
4. **No correction/backtracking affordance** (e.g., “actually…” rewrite behavior).
5. **No command mode UX** (voice edit actions, rewrite, format).
6. **No app-context modes** (email/chat/code profile cues).
7. **Settings are infrastructure-heavy but workflow-light** (good diagnostics, limited dictation behavior controls).

---

## 7) Actionable Overhaul Plan (Phased)

## Phase 0 — Stabilization & Truth Alignment (2–4 days)
- Fix control-flow semantics (menu actions, state transitions, one-shot UX labels).
- Add structured lifecycle logging IDs for a full dictation session trace.
- Update stale docs to reflect actual provider/runtime state.

**Exit criteria:** deterministic lifecycle from all entry points; docs match runtime.

## Phase 1 — Reliability Core (4–7 days)
- Implement capture interruption/device-change recovery.
- Add robust injection abstraction:
  - AX insertion first
  - paste fallback with full pasteboard type preservation
  - per-app strategy map.
- Harden error recovery paths (single provider swap path, explicit retry policies).

**Exit criteria:** repeated dictation works across app matrix without manual resets.

## Phase 2 — Real-time Dictation UX (4–6 days)
- Plumb audio level from capture into `BubbleStateSubject`.
- Surface partial results from state machine to UI overlay.
- Add success micro-state animation and transient completion feedback.
- Add latency/health badges (recording, transcribing, fallback).

**Exit criteria:** user sees live, trustworthy feedback during hold and transcribe.

## Phase 3 — Wispr-style Feature Parity Foundations (1–2 weeks)
- Introduce post-processing pipeline interface (cleanup/punctuation/backtracking hooks).
- Implement baseline filler-removal + punctuation pass.
- Add command mode routing scaffold (without full prompt catalog yet).

**Exit criteria:** first-pass output quality uplift over raw STT and extensible command framework.

## Phase 4 — Provider & Product Expansion (parallelizable)
- Implement Whisper local or formally de-scope and remove exposed option until ready.
- Implement cloud fallback provider only behind explicit opt-in.
- Expand settings to workflow controls (silence timeout, insertion mode, per-app defaults).

**Exit criteria:** provider list reflects only production-ready paths or clearly gated beta paths.

## Phase 5 — QA Hardening + Release Readiness (ongoing)
- Build deterministic smoke suite for state machine and provider resolver.
- Manual compatibility matrix pass (Mail, Slack, Notion, Google Docs, VS Code/Cursor, Terminal).
- Performance and battery profiling for idle/recording/transcribing states.

**Exit criteria:** measurable reliability SLOs and release checklist pass.

---

## 8) Risk List (Overhaul Execution)

1. **macOS permission variance risk** (dev-signed/unsigned behavior differs).
2. **Event tap reliability risk** across OS updates and input-monitoring policies.
3. **Python runtime bootstrap fragility** (network/pip/env churn).
4. **Insertion regressions** when adding AX-first path in web/electron apps.
5. **UI-thread churn risk** when streaming partial results + animations.
6. **Provider fallback confusion** if diagnostics and user-facing messaging diverge.
7. **Scope creep risk** from parity ambitions before core reliability SLOs are met.

**Risk mitigation order:** reliability + deterministic lifecycle first, parity features second.

---

## 9) Suggested Immediate Priorities (Next 3 tasks)

1. **Fix menu/start-stop semantics + session trace instrumentation.**
2. **Implement injection abstraction with AX-first + safe pasteboard restore fallback.**
3. **Ship live partial transcript + true audio-level waveform updates.**

These three changes will deliver the highest perceived quality jump with lowest architectural disruption.