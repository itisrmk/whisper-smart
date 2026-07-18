<p align="center">
  <img src="logo.png" width="128" alt="Whisper Smart logo" />
</p>

<h1 align="center">Whisper Smart</h1>

<p align="center">
  <strong>Hold a key. Speak. Release.</strong><br>
  Voice-to-text for macOS — transcribed on-device and injected straight at your cursor, in any app.
</p>

<p align="center">
  <a href="https://github.com/itisrmk/whisper-smart/releases/latest">
    <img src="https://img.shields.io/badge/Download-latest%20DMG-EC3013?style=flat-square" alt="Download the latest release" />
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-201E1D?style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Built%20with-Swift%20%2B%20SwiftUI-201E1D?style=flat-square" alt="Swift + SwiftUI" />
  <img src="https://img.shields.io/badge/Privacy-local--first-EC3013?style=flat-square" alt="Local-first" />
</p>

---

## 01 — How it works

1. **Hold your hotkey** (default: Right Command)
2. **Speak** — the app records from your mic
3. **Release** — transcription lands at your cursor

Works everywhere you type: browsers, editors, terminals, Slack, email.

## 02 — Install

1. Download **Whisper-Smart-mac.dmg** from [Releases](https://github.com/itisrmk/whisper-smart/releases/latest)
2. Drag **Whisper Smart** into **Applications**
3. Launch — it lives as a mic icon in your menu bar
4. Grant **Accessibility** and **Microphone** permissions when prompted

> Requires macOS 14 (Sonoma) or later.

## 03 — Speech providers

Pick the engine that fits your workflow in **Settings → Provider**:

| Preset | Engine | Runs locally | Setup |
|--------|--------|:---:|-------|
| **Light** | Whisper Tiny/Base | Yes | Needs Command Line Tools |
| **Balanced** | Parakeet TDT 0.6B | Yes | One-click in-app download |
| **Best** | Whisper Large-v3 Turbo | Yes | Needs Command Line Tools |
| **Cloud** | OpenAI Whisper API | No | Paste your API key |

If your provider isn't ready yet, the app falls back to **Apple Speech** (built-in, zero setup) — you're never stuck.

## 04 — Features

- **Press-and-hold or one-shot** — hold the hotkey while speaking, or click "Start Dictation" from the menu for toggle mode
- **Left/right key aware** — bind Right Command without Left Command triggering it
- **Configurable hotkey** — pick a preset or record any modifier combo in Settings
- **Terminal-friendly** — special paste handling for Terminal.app, iTerm2, Kitty, Warp, Ghostty, and more
- **Smart silence detection** — no speech means instant return to idle, no waiting
- **Writing styles** — neutral, formal, concise, casual, or developer mode with per-app overrides
- **Auto-updates** — built-in Sparkle updater checks for new versions automatically
- **Privacy-first** — local providers keep audio on your Mac; cloud is opt-in

## 05 — Customizing the hotkey

Open **Settings → Hotkey** to:

- **Pick a preset** — Right Command Hold, Left Control Hold, Option+Space, Control+Space, Fn Hold
- **Record a custom combo** — click the shortcut pill and press your keys
- **Left vs right matters** — each physical key is tracked independently

## 06 — Building from source

```bash
# Build
swift build

# Run
.build/debug/Whisper\ Smart

# Package a DMG
bash scripts/package_dmg.sh
```

## License

See [LICENSE](LICENSE) for details.
