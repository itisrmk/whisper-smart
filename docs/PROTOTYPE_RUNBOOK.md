# Prototype Runbook

End-to-end local prototype: **hotkey hold → audio capture → stub STT → text insertion**.

## Prerequisites

- macOS 14+ with Xcode Command Line Tools installed
- Accessibility permission granted to the process that runs the app (Terminal if launching from Terminal) in System Settings → Privacy & Security → Accessibility
- Input Monitoring permission granted to the same process in System Settings → Privacy & Security → Input Monitoring
- Microphone permission granted to the same process in System Settings → Privacy & Security → Microphone

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

### 2. Hotkey Hold (default: Command)
- [ ] Hold either Command key for > 0.3 s
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

### 6. Shortcut Customization
- [ ] Open Settings → Hotkey tab
- [ ] "Dictation shortcut" label shows current binding (default: "⌘ Hold")
- [ ] Preset picker lists: ⌘ Hold, ⌥ Space, ⌃ Space, Fn Hold
- [ ] Select a different preset (e.g. "⌥ Space")
  - [ ] Displayed shortcut updates immediately
  - [ ] The new shortcut is persisted — restart the app and verify it still shows "⌥ Space"
- [ ] Test the new shortcut:
  - [ ] Hold Option + Space for > 0.3 s → bubble transitions to "Listening…"
  - [ ] Release → "Transcribing…" → text pasted → back to "Ready"
- [ ] Switch back to "⌘ Hold" and verify it works again
- [ ] Changes take effect live — no app restart required

### 7. Quit
- [ ] Click menu bar icon → "Quit Visperflow" terminates the process cleanly

## Architecture Reference

```
app/App/     → Bootstrap (main.swift, AppDelegate)
app/Core/    → Pipeline (HotkeyMonitor, HotkeyBinding, AudioCapture, STTProvider, StateMachine, Injector)
app/UI/      → Presentation (MenuBar, Bubble, Settings)
```

`AppDelegate` owns the `DictationStateMachine`, bridges `DictationStateMachine.State` → `BubbleState` for the UI layer, and calls `stateMachine.activate()` on launch.

### Shortcut Pipeline

```
HotkeyBinding (model, Codable)
  ↕ persisted via UserDefaults ("hotkeyBinding")
  ↕ loaded on launch in AppDelegate
  ↕ updated live via NotificationCenter (.hotkeyBindingDidChange)
  ↓
HotkeyMonitor.updateBinding(_:)
  → stop() → reconfigure matchingKeyCodes → start()
  → DictationStateMachine continues using the same monitor instance
```
