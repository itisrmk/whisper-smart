# Whisper Smart for Linux

Hold a hotkey, speak, release — the transcript is inserted at your cursor.

This is a Linux port of the macOS Whisper Smart app. It is a separate program,
not a cross-compile: the macOS build is Swift on AppKit and SwiftUI, neither of
which exists here, and its speech engine is MLX, which is Apple Silicon only.
What carries over is the behaviour — the dictation lifecycle, the hotkey
semantics, the text-insertion strategy, the settings model — reimplemented in
Rust against the Linux desktop stack.

## Requirements

| Need | Package | Why |
|------|---------|-----|
| **Required** | `gtk4` | Settings window and overlay |
| Recommended | `gtk4-layer-shell` | Puts the recording overlay above other windows |
| Recommended | `wtype` | Types the transcript directly (primary insertion strategy) |
| Recommended | `wl-clipboard` | Clipboard-paste fallback |
| One engine | `whisper-cpp` + `ggml-cpu` | Default speech engine, no Python needed |
| GPU (optional) | `ggml-cuda` | CUDA acceleration for whisper.cpp |
| Alternative | `uv` | Provisions the Python the other engines need |

```bash
sudo pacman -S gtk4 gtk4-layer-shell wtype wl-clipboard whisper-cpp ggml-cpu

# NVIDIA GPU users, for much faster local transcription:
sudo pacman -S ggml-cuda
```

You also need to be able to read input devices, which is how the global hotkey
works at all (see [Global hotkey](#global-hotkey)):

```bash
sudo usermod -aG input "$USER"   # then log out and back in
```

## Install

```bash
cd linux
bash packaging/install.sh            # installs into ~/.local, no root needed
whisper-smart --check                # reports anything still missing
systemctl --user enable --now whisper-smart
```

For a system package, `packaging/PKGBUILD` builds one with `makepkg`.

## Usage

* **Hold** the hotkey (Right Ctrl by default), speak, release. The transcript is
  inserted where your cursor is.
* **Double-press** the hotkey to start a hands-free recording that keeps going
  until you press it again, or until you stop speaking for a couple of seconds.
* **Esc** during a recording discards it without transcribing.
* The tray icon shows the current state and opens Settings.

### Command line

```bash
whisper-smart --check                 # readiness report; non-zero if blocked
whisper-smart --list-devices          # microphones you can select
whisper-smart --mic-test 5            # record 5s and report the level
whisper-smart --list-models           # the catalog, marking what is downloaded
whisper-smart --download-model ID     # fetch weights without the GUI
whisper-smart --transcribe FILE.wav   # transcribe a file with the current provider
```

`--check` exits non-zero when something is blocking dictation, so it works from
a script or a systemd `ExecStartPre`. `--transcribe` is the quickest way to
confirm the speech engine works at all, without involving the microphone, the
hotkey, or text insertion — and `--mic-test` covers the other half.

### Picking a microphone

Device names come from cpal's ALSA host, which means they read like
`PulseAudio Sound Server` rather than the friendly names in your mixer. Entries
that cannot actually capture — rate converters, upmix plugins, and the rest of
the ALSA plumbing — are filtered out, but the remaining names are still ALSA's
view of the world rather than PipeWire's.

If you have several microphones, the reliable way to choose between them is your
mixer: PipeWire remembers a per-application capture device (`module-stream-restore`),
so moving Whisper Smart's input in `pavucontrol` sticks across restarts and
overrides both the system default and this app's own setting. Use
`whisper-smart --mic-test` to confirm you picked the right one.

## Speech engines

MLX has no Linux backend, so the macOS model catalog is replaced with three
engines that carry the same model families in a format they can actually load.
Every one of them runs entirely on your machine.

| Engine | Format | Notes |
|--------|--------|-------|
| **whisper.cpp** | GGUF | Default. Distro packages plus one file; no Python, no CUDA wheels. Slowest to start each utterance because it spawns a process. |
| **faster-whisper** | CTranslate2 | Fastest local Whisper when a matching CUDA build works. Resident daemon, so no per-utterance startup cost. |
| **Parakeet** | ONNX Runtime | The macOS build's default engine, same TDT models. Resident daemon. |

There is also an **OpenAI API** provider for the cases where a cloud round-trip
is acceptable. It is never selected implicitly: a broken local setup fails
loudly rather than quietly uploading your microphone, and cloud fallback has to
be turned on explicitly *and* have a key saved before it will engage.

If you copy a `config.toml` from a macOS install, its MLX model IDs are migrated
to the nearest Linux equivalent on load rather than being reset.

### A note on ggml backends

Arch ships `ggml` with no compute backend of its own and splits the backends
into `ggml-cpu`, `ggml-cuda`, `ggml-vulkan`, and friends. With `whisper-cpp`
installed but no backend, `whisper-cli` aborts with `GGML_ASSERT(device)` the
moment it loads a model, which on its own tells you nothing. `whisper-smart
--check` detects this specifically and names the package to install.

### About the Python engines

`faster-whisper` and Parakeet run in a virtualenv that the app creates and owns,
under `~/.local/share/whisper-smart/runtime/python`. Your system Python is never
modified. Install it from **Settings → Provider → Install runtime**.

One wrinkle worth knowing about on a rolling distro: machine-learning wheels lag
new CPython releases by months, and Arch ships those releases immediately. As of
this writing an up-to-date Arch system has Python 3.14, which has no
`ctranslate2` or `onnxruntime` wheel. The app detects this and will use a
`uv`-provisioned 3.12 instead, so `sudo pacman -S uv` is worth having. Choose
whisper.cpp if you would rather not deal with any of this.

## Global hotkey

Wayland deliberately does not let an ordinary client observe global keystrokes —
that is the security model working as intended, and it is why there is no
Wayland equivalent of the macOS Accessibility permission that the Mac build asks
for. Whisper Smart reads `/dev/input/event*` directly instead, which:

* works on any compositor (Hyprland, Sway, GNOME, KDE) and on X11;
* distinguishes left from right modifiers for free, because the kernel reports
  them as different key codes;
* only ever *observes* keys, so your hotkey still reaches the focused app.

The cost is needing read access to those devices, hence the `input` group.

## Text insertion

There is no Accessibility API on Wayland, so the macOS "write into the focused
text field" strategy has no counterpart. Two strategies are used instead:

1. **Type** the text with `wtype`, via the virtual-keyboard protocol. Works
   everywhere including terminals, and never touches your clipboard.
2. **Paste**: copy, synthesise the paste shortcut, then put your previous
   clipboard contents back. Terminals get a longer delay and `Ctrl+Shift+V`,
   because a PTY processes a paste asynchronously.

GNOME does not implement the virtual-keyboard protocol, so typing fails there
and the clipboard path is used. `whisper-smart --check` tells you which applies.

## Files

| Path | Contents |
|------|----------|
| `~/.config/whisper-smart/config.toml` | Settings. Plain TOML, safe to edit and to commit to dotfiles. |
| `~/.config/whisper-smart/credentials.toml` | API key, mode `0600`. Never written to `config.toml`. |
| `~/.local/share/whisper-smart/models/` | Downloaded weights. |
| `~/.local/share/whisper-smart/runtime/python/` | The managed virtualenv. |
| `~/.local/share/whisper-smart/transcripts.jsonl` | History. Local only. |
| `~/.local/state/whisper-smart/` | Logs. |

## Development

```bash
bash scripts/run_dev.sh          # run from the source tree, verbose logging
bash scripts/run_qa_smoke.sh     # fmt + clippy + tests + sidecar syntax
bash scripts/typecheck.sh        # cargo check only
```

### Layout

```
src/core/       State machine, settings, model catalog, text pipeline.
                No GTK, no evdev, no network — all of it unit-testable.
src/platform/   Audio (cpal), input (evdev), insertion (wtype), diagnostics.
src/stt/        Provider abstraction and the three engines.
src/ui/         GTK4 windows, the layer-shell overlay, the tray.
src/app.rs      Lifecycle and wiring, the AppDelegate equivalent.
tests/          Integration tests driving the real sidecar protocol.
python/         The STT sidecar for the CTranslate2 and ONNX engines.
```

The crate builds as a library as well as a binary, so the integration tests can
drive real components rather than only reaching them through the UI.
`tests/daemon_protocol.rs` runs the real sidecar client against stand-in
sidecars written in stdlib-only Python: they speak the same JSONL protocol as
`python/stt_daemon.py`, which covers the `ready` handshake, request/response
correlation, error propagation, and restart-after-death without needing a
multi-gigabyte model in CI.

Every asynchronous source — the hotkey reader, the audio callback, the STT
workers, the timer service — funnels into one event channel that the GTK main
loop drains, so the state machine is only ever touched from one thread. That is
the direct equivalent of the macOS build leaning on `DispatchQueue.main`.

## Differences from the macOS build

| macOS | Linux |
|-------|-------|
| MLX (Parakeet, Whisper) | whisper.cpp, faster-whisper, Parakeet ONNX |
| Apple Speech as the zero-setup default | whisper.cpp: one package, one file |
| CGEvent tap + Accessibility permission | `/dev/input` + `input` group |
| AX insertion, then ⌘V paste | `wtype`, then Ctrl+V / Ctrl+Shift+V paste |
| `NSStatusItem` | StatusNotifierItem over D-Bus |
| Floating `NSPanel` overlay | `wlr-layer-shell` surface |
| `UserDefaults` | `config.toml` |
| Keychain | `0600` file in the config directory |
| Sparkle updates | Distro package / `git pull` |

Two behavioural differences are deliberate rather than incidental:

* **No microphone permission state.** macOS gates the mic behind TCC, so the
  Swift state machine carries a pending-permission flag and an async grant
  callback. A PipeWire client needs no such prompt, so a device that will not
  open is simply a capture error.
* **Fallback never reaches for the cloud on its own.** macOS falls back to Apple
  Speech, which is always present and always local. Linux has no such universal
  engine, so rather than silently substituting a network service, a broken local
  provider reports what is wrong and what fixes it.
