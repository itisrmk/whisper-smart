# VisperflowClone — Architecture

## Overview

VisperflowClone is a macOS menu-bar utility that provides system-wide
press-and-hold dictation. The user holds a hotkey, speaks, releases the key,
and the transcribed text is injected into whatever app has focus.

The core logic lives in **`app/Core/`** and is intentionally decoupled from any
UI framework so it can be driven by SwiftUI, AppKit, or unit tests.

---

## Module Map

```
app/
└── Core/
    ├── HotkeyMonitor.swift          # Global hotkey listener
    ├── AudioCaptureService.swift     # Microphone capture via AVAudioEngine
    ├── STTProvider.swift             # Speech-to-text protocol + stub
    ├── ClipboardInjector.swift       # Text injection into frontmost app
    └── DictationStateMachine.swift   # Orchestrator / state machine
```

---

## Modules

### HotkeyMonitor

| Responsibility | Detect press-and-hold of a configurable global hotkey |
|---|---|
| Key API | `start()`, `stop()`, `onHoldStarted`, `onHoldEnded` |
| Mechanism | `CGEvent.tapCreate` (session-level, listen-only) |
| Permissions | Requires **Accessibility** (System Settings → Privacy) |
| Threading | Callbacks fire on the main run-loop |

The monitor distinguishes a deliberate hold from a quick tap via a configurable
`minimumHoldDuration` (default 0.3 s). Modifier-only keys (⌘, ⌥, ⇧, ⌃) are
handled through `.flagsChanged` events.

### AudioCaptureService

| Responsibility | Capture microphone audio as PCM buffers |
|---|---|
| Key API | `start()`, `stop()`, `onBuffer`, `onError` |
| Mechanism | `AVAudioEngine` input-node tap |
| Output format | Float32, 16 kHz, mono (configurable) |
| Permissions | Requires **Microphone** (granted via `AVCaptureDevice.requestAccess`) |

The engine handles sample-rate conversion transparently when the hardware rate
differs from the requested rate. Buffers are delivered on the audio engine's
real-time thread; consumers should copy data off-thread for heavy processing.

### STTProvider (Protocol)

| Responsibility | Convert audio buffers into text |
|---|---|
| Key API | `beginSession()`, `feedAudio(buffer:time:)`, `endSession()`, `onResult`, `onError` |
| Deliverable | `STTResult` with `.text`, `.isPartial`, `.confidence` |

This is a protocol so backends can be swapped at runtime:

| Provider | Status | Notes |
|---|---|---|
| `StubSTTProvider` | Included | No-op placeholder for dev/test |
| `WhisperLocalProvider` | TODO | On-device via whisper.cpp |
| `WhisperAPIProvider` | TODO | OpenAI Whisper REST API |
| `AppleSpeechProvider` | TODO | Apple Speech framework |

### ClipboardInjector

| Responsibility | Deliver transcribed text to the focused text field |
|---|---|
| Key API | `inject(text:)` |
| Strategies | `.pasteboard` (default) — copies text, synthesises ⌘V |
|             | `.keyEvents` — character-by-character CGEvent posting (TODO) |

The pasteboard strategy saves & restores the user's clipboard so dictation
doesn't clobber copied content.

### DictationStateMachine

| Responsibility | Orchestrate the full dictation lifecycle |
|---|---|
| Key API | `activate()`, `deactivate()`, `onStateChange` |

State diagram:

```
  ┌──────┐  hold started   ┌───────────┐  hold ended   ┌──────────────┐
  │ Idle │ ───────────────▶ │ Recording │ ────────────▶ │ Transcribing │
  └──────┘                  └───────────┘               └──────┬───────┘
      ▲                                                        │
      │              result received / error                   │
      └────────────────────────────────────────────────────────┘
```

The state machine owns instances of all four modules above, wires their
callbacks together, and exposes a single `onStateChange` callback for the UI
layer to observe.

---

## Threading Model

| Thread | Used by |
|---|---|
| Main run-loop | HotkeyMonitor callbacks, state transitions, UI updates |
| AVAudioEngine real-time thread | `AudioCaptureService.onBuffer` delivery |
| Background (provider-defined) | STT inference / network calls |

STT results and errors are dispatched back to the main queue by the state
machine before being acted upon.

---

## Permissions Required

| Permission | Purpose | Prompt trigger |
|---|---|---|
| Accessibility | Global hotkey monitoring via CGEvent tap | First `HotkeyMonitor.start()` |
| Microphone | Audio capture | First `AudioCaptureService.start()` |

---

## Open TODOs

- [ ] Implement a real `STTProvider` (whisper.cpp or OpenAI API)
- [ ] Implement `ClipboardInjector.keyEvents` strategy for non-pasteboard injection
- [ ] Add CoreAudio device-change listener in `AudioCaptureService` for mic hot-swap
- [ ] Add microphone permission request flow before capture starts
- [ ] Surface Accessibility permission status to the UI
- [ ] Add live partial-result overlay during recording
- [ ] Unit tests for `DictationStateMachine` state transitions
