# Prototype Runbook

End-to-end local runbook for the current app behavior:

**hotkey hold or menu one-shot → audio capture → real STT provider (Apple Speech / Parakeet local) → text insertion**.

## Runtime Reality (Phase 0)

- ✅ `AppleSpeechSTTProvider` is implemented and production-usable.
- ✅ `ParakeetSTTProvider` is implemented (local ONNX via `scripts/parakeet_infer.py`) with runtime bootstrap + model source checks.
- ✅ Provider resolver/diagnostics chooses requested provider or falls back with explicit reason.
- ⚠️ `WhisperLocal` and `WhisperAPI` kinds exist in settings/diagnostics but are not implemented providers yet.
- ✅ Menu action semantics: **Start Dictation** starts an immediate one-shot recording; during recording it becomes **Stop Dictation**.
- ✅ Dictation lifecycle now includes a brief **success** micro-state after final transcript before returning to idle.
- ✅ Text insertion strategy order is **AX-first**, then paste fallback.
- ✅ Paste fallback preserves/restores full clipboard types when possible and avoids restoring if clipboard changed externally during insertion.
- ✅ Audio capture now listens for engine reconfiguration + default input-device changes and safely stops the active session with explicit manual-retry messaging.

## Prerequisites

- macOS 14+ with Xcode Command Line Tools
- Accessibility permission (for hotkey monitoring)
- Input Monitoring permission (for global key event tap reliability)
- Microphone permission
- Speech Recognition permission (required for Apple Speech provider)

## Verification Commands

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

```bash
./VisperflowClone
```

## Manual Smoke Test

### 1) Launch
- [ ] Menu bar icon appears
- [ ] Floating bubble appears with state **Ready**
- [ ] Provider line shows resolved provider (or fallback reason)

### 2) Hotkey hold-to-dictate
- [ ] Hold configured hotkey (default Command hold)
- [ ] Bubble enters **Listening…**
- [ ] Release hotkey
- [ ] Bubble enters **Transcribing…**
- [ ] Final text is inserted into focused editor
- [ ] Bubble briefly shows **Done** then returns to **Ready**

### 3) Menu action semantics
- [ ] Open menu: primary action reads **Start Dictation** when idle
- [ ] Click **Start Dictation**: recording begins immediately (no hotkey required)
- [ ] Primary action changes to **Stop Dictation** while recording
- [ ] Click **Stop Dictation** to end recording and transcribe
- [ ] During transcription, primary action is disabled and labeled **Transcribing…**

### 4) Provider switching
- [ ] Open Settings → Provider
- [ ] Switch between Apple Speech and Parakeet
- [ ] Diagnostics line updates with effective provider/fallback info
- [ ] No duplicate provider replacement side effects (single swap path)

### 5) Error + recovery
- [ ] Deny a required permission and verify error state is surfaced in bubble/menu
- [ ] Grant permission and use **Retry Hotkey Monitor** if needed
- [ ] Confirm hotkey retry behavior is explicit (no duplicate rapid retries, bounded auto-retry attempts)

### 6) Insertion strategy + clipboard safety
- [ ] Dictate into a standard text field with Accessibility enabled and verify insertion succeeds
- [ ] While dictation is active, copy rich content (e.g., formatted text/image) in another app; verify dictation fallback paste does not permanently clobber clipboard
- [ ] Verify fallback still inserts text in apps where AX insertion is unavailable

### 7) Audio interruption/device change
- [ ] Start dictation, then switch default input device (System Settings → Sound)
- [ ] Verify dictation stops safely and app surfaces explicit manual retry guidance
- [ ] Press **Start Dictation** again and verify capture resumes on the new input device

## Troubleshooting

### Type-check/build failures
Re-run:

```bash
bash scripts/typecheck.sh
```

then:

```bash
swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -o VisperflowClone \
  app/**/*.swift
```

### Parakeet unavailable in diagnostics
- Confirm model source is configured/downloaded in settings.
- Confirm Python runtime bootstrap status is ready.
- Check fallback reason shown in menu/provider diagnostics.

## Source Map

- `app/App/` → bootstrap + dependency wiring
- `app/Core/` → hotkey, audio, state machine, providers, injector
- `app/UI/` → menu bar, bubble, settings
- `scripts/parakeet_infer.py` → local Parakeet inference runner
