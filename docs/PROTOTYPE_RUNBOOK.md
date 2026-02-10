# Prototype Runbook

End-to-end local prototype: **hotkey hold → audio capture → stub STT → text insertion**.

## Prerequisites

- macOS 14+ with Xcode Command Line Tools installed
- Accessibility permission granted to Terminal (System Settings → Privacy & Security → Accessibility)
- Microphone permission granted to Terminal (System Settings → Privacy & Security → Microphone)

## Type-Check

```bash
bash scripts/typecheck.sh
```

All Swift files under `app/` are compiled with `swiftc -typecheck`. No binary is produced — this validates syntax and types only.

## Build & Run (swiftc)

```bash
swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -o VisperflowClone \
  app/**/*.swift

./VisperflowClone
```

The app starts as a menu-bar-only process (no Dock icon).

## Manual Test Steps

### 1. App Launch
- [ ] Menu bar shows a microphone icon
- [ ] Floating bubble appears in the top-right corner, state "Ready"

### 2. Hotkey Hold (Right Command)
- [ ] Hold Right Command for > 0.3 s
- [ ] Bubble transitions to "Listening…" (blue, pulsing ring)
- [ ] Menu bar icon changes to waveform

### 3. Hotkey Release
- [ ] Release Right Command
- [ ] Bubble transitions to "Transcribing…" (purple)
- [ ] Stub provider immediately delivers `[stub transcription]`
- [ ] Text `[stub transcription]` is pasted into the focused text field (via ⌘V)
- [ ] Bubble returns to "Ready" (idle)

### 4. Error Path
- [ ] If no microphone is connected, state transitions to error with a clear message
- [ ] Bubble shows error state (red, triangle icon)

### 5. Settings
- [ ] Click menu bar icon → "Settings…" opens settings window
- [ ] Tabs: General, Hotkey, Provider are present

### 6. Quit
- [ ] Click menu bar icon → "Quit Visperflow" terminates the process cleanly

## Architecture Reference

```
app/App/     → Bootstrap (main.swift, AppDelegate)
app/Core/    → Pipeline (HotkeyMonitor, AudioCapture, STTProvider, StateMachine, Injector)
app/UI/      → Presentation (MenuBar, Bubble, Settings)
```

`AppDelegate` owns the `DictationStateMachine`, bridges `DictationStateMachine.State` → `BubbleState` for the UI layer, and calls `stateMachine.activate()` on launch.
