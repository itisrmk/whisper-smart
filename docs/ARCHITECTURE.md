# VisperflowClone — Architecture

## Overview

VisperflowClone is a macOS menu-bar dictation app with two primary interaction paths:

1. **Press-and-hold hotkey dictation** (global event tap)
2. **Menu-driven one-shot dictation** (explicit start/stop action)

Core pipeline:

`Hotkey/Menu Trigger → AudioCaptureService → STTProvider → ClipboardInjector`

`AppDelegate` wires dependencies and bridges core lifecycle state to UI state.

---

## Module Map

```
app/
├── App/
│   ├── main.swift
│   └── AppDelegate.swift
├── Core/
│   ├── DictationStateMachine.swift
│   ├── HotkeyMonitor.swift
│   ├── AudioCaptureService.swift
│   ├── STTProvider.swift
│   ├── AppleSpeechSTTProvider.swift
│   ├── ParakeetSTTProvider.swift
│   ├── STTProviderDiagnostics.swift
│   ├── ClipboardInjector.swift
│   └── (Parakeet runtime/model support files)
└── UI/
    ├── MenuBarController.swift
    ├── BubblePanelController.swift
    ├── FloatingBubbleView.swift
    └── Settings*.swift
```

---

## Dictation Lifecycle

`DictationStateMachine.State`:

- `.idle`
- `.recording`
- `.transcribing`
- `.success` (brief micro-state after final transcript/injection)
- `.error(String)`

Lifecycle:

```
idle -> recording -> transcribing -> success -> idle
                    \-> error
```

Notes:
- `success` is transient and automatically resets to `idle`.
- Final text injection happens on non-partial STT result before entering `success`.
- Provider swap (`replaceProvider`) is a single replacement path and resets active sessions safely.

---

## Provider System (Current Truth)

`STTProvider` protocol supports begin/feed/end session callbacks and result/error delivery.

### Implemented providers

- ✅ **Apple Speech** (`AppleSpeechSTTProvider`)
  - Native Speech framework path
  - Emits partial + final callbacks
- ✅ **Parakeet local** (`ParakeetSTTProvider`)
  - Local ONNX inference via Python runner (`scripts/parakeet_infer.py`)
  - Integrates model source validation + runtime bootstrap status

### Declared but not implemented providers

- ⚠️ Whisper local
- ⚠️ Whisper API

Resolver/diagnostics selects effective provider and publishes fallback reason when requested provider is unavailable.

---

## UI State Mapping

`AppDelegate` maps core state to `BubbleState`:

- `idle -> .idle`
- `recording -> .listening`
- `transcribing -> .transcribing`
- `success -> .success`
- `error -> .error`

`MenuBarController` keeps action labels aligned with behavior:

- Idle/success/error: **Start Dictation**
- Recording: **Stop Dictation**
- Transcribing: **Transcribing…** (disabled)

---

## Permissions

- Accessibility (global hotkey monitor/event tap)
- Input Monitoring (global key capture reliability)
- Microphone (audio capture)
- Speech Recognition (Apple Speech provider)

`PermissionDiagnostics` logs and surfaces runtime status.

---

## Reliability Behavior (Phase 1)

- `ClipboardInjector` now uses explicit strategy order:
  1. Accessibility insertion into focused text element (`AXValue` + `AXSelectedTextRange`).
  2. Pasteboard + Cmd-V fallback.
- Pasteboard fallback captures/restores full pasteboard items/types (data + property list forms) and only restores when clipboard change count is unchanged, preventing clobber of user copies made during injection.
- `AudioCaptureService` now emits interruption hooks for:
  - `AVAudioEngineConfigurationChange`
  - default input-device changes (`kAudioHardwarePropertyDefaultInputDevice` listener)
- `DictationStateMachine` treats interruption/device-change as safe-stop errors with explicit manual retry messaging (no hidden automatic retry).
- Accessibility hotkey monitor retry policy is explicit and bounded (single pending retry task, max attempts), avoiding duplicate retry loops.

## Known Gaps / Next Reliability Work

- Audio-level waveform plumbing + partial transcript overlay are still limited.
