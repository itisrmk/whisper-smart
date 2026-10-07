# Whisper Smart for Windows

Hold a hotkey, speak, release — the transcript is inserted at your cursor.

This is a Windows port of the macOS Whisper Smart app, built the same way as
the Linux port: a separate Rust program, not a cross-compile. The macOS build
is Swift on AppKit and SwiftUI, and its speech engine is MLX, which is Apple
Silicon only. What carries over is the behaviour — the dictation lifecycle,
the hotkey semantics, the text-insertion strategy, the settings model, the
design language — reimplemented against the Windows desktop stack. The
`linux/` and `windows/` trees mirror each other module for module, and they
share the same speech engines and model catalog.

## Install

Download `whisper-smart-X.Y.Z-windows-x86_64.zip` from the
[releases page](https://github.com/itisrmk/whisper-smart/releases), unzip it
anywhere, and run `whisper-smart.exe`. The Settings window opens; closing it
keeps the app running in the notification area (system tray), which is where
it lives — left-click the tray icon to toggle dictation, right-click for the
menu, including Quit. Only one copy runs at a time; launching the exe again
just reminds you it is already in the tray.

Windows SmartScreen will warn about an unsigned app on first launch: choose
*More info → Run anyway*. To start with Windows, put a shortcut to
`whisper-smart.exe` in the Startup folder (`Win+R`, then `shell:startup`).

First-run setup, all from **Settings → Provider**:

1. Press **Install whisper.cpp** — the app downloads the official prebuilt
   `whisper-cli.exe` (checksum-verified) into its own data directory.
2. Download a model. **Balanced** (Whisper Small) is a good start.
3. Hold **Right Ctrl**, speak, release.

Nothing is installed system-wide, no installer runs, and nothing leaves your
machine unless you explicitly choose the Cloud provider.

## Usage

* **Hold** the hotkey (Right Ctrl by default), speak, release. The transcript
  is inserted where your cursor is.
* **Double-press** the hotkey to start a hands-free recording that keeps going
  until you press it again, or until you stop speaking for a couple of seconds.
* **Esc** during a recording discards it without transcribing.
* The tray icon shows the current state; left-click toggles dictation and
  right-click opens the menu.

### Command line

Run from a terminal in the install folder:

```
whisper-smart.exe --check                 # readiness report; non-zero if blocked
whisper-smart.exe --list-devices          # microphones you can select
whisper-smart.exe --mic-test 5            # record 5s and report the level
whisper-smart.exe --list-models           # the catalog, marking what is downloaded
whisper-smart.exe --download-model ID     # fetch weights without the GUI
whisper-smart.exe --transcribe FILE.wav   # transcribe a file with the current provider
```

## Speech engines

The same three local engines as the Linux build, carrying the same model
families the macOS build runs through MLX:

| Engine | Format | Notes |
|--------|--------|-------|
| **whisper.cpp** | GGUF | Default. The app installs the official prebuilt binary; no Python. Slowest to start each utterance because it spawns a process. |
| **faster-whisper** | CTranslate2 | Fastest local Whisper when a matching CUDA build works. Resident daemon, so no per-utterance startup cost. |
| **Parakeet** | ONNX Runtime | The macOS build's default engine, same TDT models. Resident daemon. |

There is also an **OpenAI API** provider for the cases where a cloud
round-trip is acceptable. It is never selected implicitly: a broken local
setup fails loudly rather than quietly uploading your microphone, and cloud
fallback has to be turned on explicitly *and* have a key saved before it will
engage.

### About the Python engines

`faster-whisper` and Parakeet run in a virtualenv the app creates and owns
under `%LOCALAPPDATA%\whisper-smart\runtime\python`. Windows ships no Python
(the `python` on a default PATH is the Microsoft Store stub), so the app
prefers [uv](https://docs.astral.sh/uv/), which provisions a known-good
CPython on demand:

```
winget install astral-sh.uv
```

A real Python 3.10–3.13 install works too. Install the runtime from
**Settings → Provider → Advanced → Install runtime**. Choose whisper.cpp if
you would rather not deal with any of this.

## Global hotkey

A low-level keyboard hook (`WH_KEYBOARD_LL`) — no permission prompt, works in
every app, and left/right modifiers arrive as distinct key codes, so "Right
Ctrl" genuinely means the right one. Keys are observed, never consumed, so the
hotkey still reaches the focused application.

One caveat: windows of programs running **as Administrator** do not deliver
keystrokes to an unelevated hook, so the hotkey pauses while such a window has
focus (run Whisper Smart elevated too if you dictate into admin tools).

## Text insertion

1. **Type** the text via `SendInput` with `KEYEVENTF_UNICODE` — works in every
   focused field including terminals, layout-independent, never touches the
   clipboard.
2. **Paste**: copy, synthesise Ctrl+V, then restore your previous clipboard.
   Terminals get longer delays because the console host processes paste input
   asynchronously. Multi-line transcripts always paste, because a typed
   newline is an Enter keypress and would submit chat boxes.

## Files

| Path | Contents |
|------|----------|
| `%APPDATA%\whisper-smart\config.toml` | Settings. Plain TOML, safe to edit. |
| `%APPDATA%\whisper-smart\credentials.toml` | API key. Never written to config.toml. |
| `%LOCALAPPDATA%\whisper-smart\models\` | Downloaded weights. |
| `%LOCALAPPDATA%\whisper-smart\runtime\` | The managed virtualenv and whisper.cpp binaries. |
| `%LOCALAPPDATA%\whisper-smart\transcripts.jsonl` | History. Local only. |
| `%LOCALAPPDATA%\whisper-smart\logs\` | Log file. |

Uninstalling is: quit from the tray, delete the unzipped folder, and delete
those two directories.

## Development

```bash
cargo build --release
bash scripts/run_qa_smoke.sh     # fmt + clippy + tests + sidecar syntax
bash scripts/typecheck.sh        # cargo check only
```

### Layout

```
src/core/       State machine, settings, model catalog, text pipeline.
                No Win32, no egui, no network — all of it unit-testable.
src/platform/   Audio (cpal/WASAPI), input (WH_KEYBOARD_LL), insertion
                (SendInput), diagnostics.
src/stt/        Provider abstraction and the engines.
src/ui/         egui settings window, overlay, and the tray icon.
src/app.rs      Lifecycle and wiring, the AppDelegate equivalent.
src/bus.rs      The event channel + UI wake-up every async source posts into.
tests/          Integration tests driving the real sidecar protocol.
python/         The STT sidecar for the CTranslate2 and ONNX engines.
```

The crate builds as a library as well as a binary, so the integration tests
can drive real components rather than only reaching them through the UI. It
also builds (with stubbed platform integrations) on Unix hosts, so the
portable core can be developed and tested without a Windows machine; the
Win32 layer is verified there with
`cargo check --target x86_64-pc-windows-msvc`.

Every asynchronous source — the keyboard hook, the audio callback, the STT
workers, the timer service — funnels into one event channel that the egui
frame drains, so the state machine is only ever touched from one thread. Each
sender wakes the UI through `bus::EventBus`, so the app idles at zero frames
per second and still reacts immediately. That is the direct equivalent of the
macOS build leaning on `DispatchQueue.main`.

## Differences from the macOS build

| macOS | Windows |
|-------|---------|
| MLX (Parakeet, Whisper) | whisper.cpp, faster-whisper, Parakeet ONNX |
| Apple Speech as the zero-setup default | whisper.cpp: one click installs the official binary |
| CGEvent tap + Accessibility permission | `WH_KEYBOARD_LL` hook, no permission needed |
| AX insertion, then ⌘V paste | `SendInput` Unicode typing, then Ctrl+V paste |
| `NSStatusItem` | `Shell_NotifyIcon` tray item |
| Floating `NSPanel` overlay | Always-on-top borderless overlay window |
| `UserDefaults` | `config.toml` |
| Keychain | File under the user profile's ACLs |
| Sparkle updates | Download the next zip |

Two behavioural differences are deliberate rather than incidental, matching
the Linux port:

* **No microphone permission state.** macOS gates the mic behind TCC per app;
  the Windows microphone toggle is system-wide and a denied device simply
  fails to open, so it surfaces as a capture error with advice.
* **Fallback never reaches for the cloud on its own.** An unusable local
  provider reports what is wrong and how to fix it, rather than silently
  substituting a network service.
