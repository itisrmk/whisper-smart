# iOSWhisperSmart (Phase 1 MVP)

Native SwiftUI iOS dictation app scaffold, created separately from the existing macOS app.

## What is implemented

- **Dark-first premium SwiftUI UI** with cards, polished mic button, and animated waveform placeholder.
- **Live dictation pipeline** using `AVAudioEngine` + Apple `Speech` framework.
- **Session state machine**: `idle`, `listening`, `partial`, `final`, `error`.
- **Partial transcript rendering** in real time.
- **Output actions**: Copy to clipboard + system share sheet.
- **App Shortcut / App Intent**: "Start Dictation".
- **Settings screen** with full engine policy controls:
  - Local (Apple Speech)
  - Cloud (OpenAI)
  - Balanced (cloud + local fallback)
- **Cloud policy enforcement** for every cloud path (including explicit Cloud mode):
  - Cloud toggle must be ON
  - User consent must be ON
  - OpenAI API key must exist
  - Clear blocked-status messaging in runtime/settings UI when cloud is requested but disallowed
- **Transcript post-processing** with style modes + replacement rules.
- **Transcript history + reliability metrics + balanced fallback counters.**
- **Live Activities integration** end-to-end with ActivityKit updates + WidgetKit `ActivityConfiguration` (Lock Screen + Dynamic Island UI).
- **Permission onboarding** + privacy copy for microphone and speech recognition.
- **Keyboard Companion extension** for inserting latest dictated text into any app.
- **App Group handoff store** (`KeyboardCompanionStore`) for latest transcript + recent snippets.
- **Modular structure** across `Core/AppCore`, `Core/Audio`, `Core/STTAdapters`, `Core/UI`, and `Features/*`.
- **Unit tests** for reducer transitions + keyboard handoff storage logic.

## Structure

- `App/` app entry and tab shell
- `Core/AppCore/` state machine + reducer
- `Core/Audio/` Apple speech recognizer + audio capture
- `Core/STTAdapters/` STT abstractions + engine policy
- `Core/UI/` theme + reusable components
- `Features/Dictation|Settings|Onboarding/` screens + view model
- `Intents/` AppIntent + AppShortcuts
- `KeyboardExtension/` custom keyboard extension UI + insert actions
- `Utilities/` share sheet wrapper
- `Tests/` unit tests for state transitions and keyboard handoff

## Setup

> **Mandatory:** run bootstrap before every build/test (especially on clean checkout or after `project.yml` changes).
> The checked-in `.xcodeproj` is generated from `project.yml`; bootstrap keeps them in sync and prevents config drift.

```bash
cd iOSWhisperSmart
./Scripts/bootstrap.sh
open iOSWhisperSmart.xcodeproj
```

If `xcodegen` is missing:

```bash
brew install xcodegen
```

## Verify

Preferred one-shot integrity check (bootstrap + drift check + scheme/target presence + builds/tests):

```bash
cd iOSWhisperSmart
./Scripts/verify_config_integrity.sh
```

Manual step-by-step verification:

Generate project:

```bash
cd iOSWhisperSmart
./Scripts/bootstrap.sh
```

Build app:

```bash
xcodebuild -project iOSWhisperSmart.xcodeproj -scheme iOSWhisperSmart -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Run tests:

```bash
xcodebuild -project iOSWhisperSmart.xcodeproj -scheme iOSWhisperSmart -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Build keyboard extension:

```bash
xcodebuild -project iOSWhisperSmart.xcodeproj -scheme iOSWhisperSmartKeyboard -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## Keyboard Companion

WhisperSmart ships with a hybrid keyboard extension designed for Apple-style typing + dictation handoff:

1. Use full QWERTY typing with light Apple-style keys (letters, shift, backspace, space, return) and keep the system globe/mic behavior unchanged.
2. Tap **123 / ABC** to switch between letters and numbers/symbols.
3. Use the top accessory row actions: **Insert Latest** and **Mic** (SF Symbol button styling).
4. Tap **Mic** to enter a dark listening panel (X cancel / ✓ confirm pattern).
5. The keyboard triggers `whispersmart://dictate` to hand off capture to the main app while polling shared App Group transcript state.
6. When a newer transcript arrives, the panel switches to **Ready**; tap ✓ to insert.
7. **Allow Full Access must be enabled** for keyboard-to-app handoff and shared snippets/transcript sync.

### Enable it on device/simulator

1. Open **Settings → General → Keyboard → Keyboards → Add New Keyboard...**
2. Select **WhisperSmart Keyboard**.
3. Tap **WhisperSmart Keyboard** and enable **Allow Full Access**.
4. Return to any text field, long-press or tap 🌐 and switch to WhisperSmart Keyboard.

### Limitations

- Keyboard extensions do **not** record microphone audio directly.
- Use the keyboard **🎙** mic key to open the listening panel and trigger app/system capture path.
- The keyboard reads only what the main app has already written to shared storage, then enables ✓ insert when newer text is detected.
- Without **Allow Full Access**, keyboard-to-app launch and shared transcript handoff are blocked.

## Known iOS constraints

- iOS apps cannot set **global hotkeys** like macOS menu bar utilities.
- Keyboard extensions cannot continuously capture mic audio for full-app dictation workflows.
- Live transcription quality and latency depend on device model, locale support, and current system availability of Apple Speech services.

## Phase 2 ideas (not implemented)

- Wire cloud STT provider(s) with explicit consent + transport security.
- Add transcript history, export formats, and richer post-processing.
- Add resilience features (auto-retry strategy, network-aware policy switching).
- Add more complete App Intent parameterization and Shortcuts responses.
