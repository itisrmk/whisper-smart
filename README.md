<p align="center">
  <img src="logo.png" width="128" alt="Whisper Smart logo" />
</p>

<h1 align="center">Whisper Smart</h1>

<p align="center">
  <strong>Hold a key. Speak. Release.</strong><br>
  Voice-to-text for macOS and Linux — transcribed on-device and injected straight at your cursor, in any app.
</p>

<p align="center">
  <a href="https://github.com/itisrmk/whisper-smart/releases/latest">
    <img src="https://img.shields.io/badge/Download-latest%20release-EC3013?style=flat-square" alt="Download the latest release" />
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-201E1D?style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Linux-Wayland%20%2B%20GTK4-201E1D?style=flat-square" alt="Linux, Wayland and GTK4" />
  <img src="https://img.shields.io/badge/Privacy-local--first-EC3013?style=flat-square" alt="Local-first" />
</p>

---

## 01 — How it works

1. **Hold your hotkey** (Right Command on macOS, Right Control on Linux)
2. **Speak** — the app records from your mic
3. **Release** — transcription lands at your cursor

Works everywhere you type: browsers, editors, terminals, Slack, email.

Two apps, one product. macOS is Swift and SwiftUI with MLX for speech; Linux is
Rust and GTK4 with whisper.cpp. They are not a cross-compile of each other —
neither platform's UI toolkit or speech runtime exists on the other — but the
dictation lifecycle, hotkey semantics, insertion strategies and settings model
are the same, and every release ships both from one tag.

## 02 — Install

Both platforms are published on the same
[release](https://github.com/itisrmk/whisper-smart/releases/latest).

### macOS

1. Download **Whisper-Smart-mac.dmg**
2. Drag **Whisper Smart** into **Applications**
3. Launch — it lives as a mic icon in your menu bar
4. Grant **Accessibility** and **Microphone** permissions when prompted

> Requires macOS 14 (Sonoma) or later. Updates arrive automatically through Sparkle.

### Linux

```bash
# Prebuilt tarball (built on Arch, installs under ~/.local, no root)
tar xzf whisper-smart-X.Y.Z-linux-x86_64.tar.gz
./whisper-smart-X.Y.Z-linux-x86_64/install.sh

# Or from source, on any distro
git clone https://github.com/itisrmk/whisper-smart
cd whisper-smart/linux && bash packaging/install.sh

whisper-smart --check                     # reports anything still missing
systemctl --user enable --now whisper-smart
```

> Needs a GTK 4 desktop and membership of the `input` group
> (`sudo usermod -aG input "$USER"`), which is how a global hotkey works at all
> under Wayland. `whisper-smart --check` prints the exact command for anything
> missing. Full setup: **[linux/README.md](linux/README.md)**.

## 03 — Speech providers

Pick the engine that fits your workflow in **Settings → Provider**. Every local
engine keeps audio on your machine; cloud is opt-in and never a silent fallback.

| | macOS | Linux |
|---|---|---|
| **Default local** | Whisper Large-v3 Turbo (MLX) | Whisper Large-v3 Turbo (whisper.cpp) |
| **Fast local** | Whisper Tiny/Base (MLX) | faster-whisper |
| **Alternative local** | Parakeet TDT 0.6B (MLX) | Parakeet TDT (ONNX) |
| **Cloud** | OpenAI Whisper API | OpenAI Whisper API |
| **Zero-setup fallback** | Apple Speech (built in) | — |
| **GPU** | Apple Silicon via MLX | NVIDIA via `ggml-cuda` |

On macOS an unready provider falls back to Apple Speech, so you are never
stuck. Linux has no such system engine, so it says what is missing and how to
fix it instead — and never silently sends your audio to the cloud.

## 04 — Features

- **Press-and-hold or one-shot** — hold the hotkey while speaking, or start dictation from the menu for toggle mode
- **Left/right key aware** — bind the right-hand modifier without the left one triggering it
- **Configurable hotkey** — pick a preset or record any modifier combo in Settings
- **Terminal-friendly** — paste handling tuned for Terminal.app, iTerm2, Kitty, Warp, Ghostty, Alacritty, foot
- **Smart silence detection** — no speech means instant return to idle, no waiting
- **Writing styles** — neutral, formal, concise, casual, or developer mode with per-app overrides
- **History** — recent transcripts, re-insertable with one click
- **Privacy-first** — local providers keep audio on your machine; cloud is opt-in

## 05 — Customizing the hotkey

Open **Settings → Hotkey** to pick a preset or record a custom combo. Each
physical key is tracked independently, so Right Command and Left Command are
different bindings.

| | macOS | Linux |
|---|---|---|
| Default | Right Command hold | Right Control hold |
| Mechanism | `CGEvent` tap (Accessibility permission) | `/dev/input` via evdev (`input` group) |
| Insertion | Accessibility `AXValue`, then ⌘V paste | `wtype`, then clipboard paste |

## 06 — Building from source

```bash
# macOS
swift build && .build/debug/Whisper\ Smart
bash scripts/run_qa_smoke.sh

# Linux
cd linux
cargo build --release && ./target/release/whisper-smart --check
bash scripts/run_qa_smoke.sh
```

Architecture, and the file-by-file mapping between the two ports, is in
[CLAUDE.md](CLAUDE.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[linux/README.md](linux/README.md).

## 07 — Releases

One tag, both platforms. Every `vX.Y.Z` carries the macOS DMG, the Sparkle
appcast, the Linux tarball and its checksum, built from the same commit — the
tag is only created once both builds pass. See
[docs/RELEASE.md](docs/RELEASE.md).

## License

See [LICENSE](LICENSE) for details.
