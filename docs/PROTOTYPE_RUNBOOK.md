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
cd /path/to/VisperflowClone
```

```bash
swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -o VisperflowClone \
  app/**/*.swift
```

```bash
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

### 6. Shortcut Customization — Preset Picker
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

### 6b. Shortcut Customization — Shortcut Recorder
The recorder lets you capture a custom modifier + key combo instead of choosing
a preset.

- [ ] Open Settings → Hotkey tab
- [ ] Click the **"Record"** button (shows a record icon)
  - [ ] Button changes to **"Press keys…"** with a red accent
  - [ ] Helper text appears: "Press a modifier + key combo (e.g. ⌥ Space). Press Esc to cancel."
  - [ ] Preset picker is disabled while recording
- [ ] **Record a custom shortcut:**
  - [ ] Press a modifier + key combo (e.g. ⌃ ⇧ K)
  - [ ] "Dictation shortcut" pill updates to show the recorded combo (e.g. "⌃ ⇧ K")
  - [ ] Preset picker shows "Custom" (since it doesn't match a built-in preset)
  - [ ] The new binding is persisted — restart the app and verify it still shows "⌃ ⇧ K"
  - [ ] The new shortcut works for hold-to-dictate
- [ ] **Cancel recording with Escape:**
  - [ ] Click "Record", then press Esc
  - [ ] Recording stops, previous shortcut is unchanged
- [ ] **Validation — keys without modifiers are rejected:**
  - [ ] Click "Record", press a plain key (e.g. just "K" with no modifiers)
  - [ ] Recording does NOT accept it; stays in recording mode waiting for a valid combo
- [ ] **Switch back to a preset after recording custom:**
  - [ ] Select a preset from the picker (e.g. "⌘ Hold")
  - [ ] Shortcut updates, preset picker shows the preset name again

### 7. Quit
- [ ] Click menu bar icon → "Quit Visperflow" terminates the process cleanly

## Troubleshooting

### "Input HW format and tap format not matching" crash

This crash occurs when `installTap(format:)` is called with a format that
differs from the input node's native hardware output format. For example, the
hardware may run at 48 kHz stereo while the tap requests 16 kHz mono.

**Fix (applied):** The tap is now installed using the hardware format returned by
`inputNode.outputFormat(forBus: 0)`. An `AVAudioConverter` converts each buffer
to the desired 16 kHz mono Float32 format before forwarding it to consumers.

If you see this crash after future changes, verify that the format passed to
`installTap` matches `inputNode.outputFormat(forBus: 0)`.

### Rebuild after code changes

```bash
cd /path/to/VisperflowClone
```

```bash
bash scripts/typecheck.sh
```

```bash
swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -o VisperflowClone \
  app/**/*.swift
```

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
