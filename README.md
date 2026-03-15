<p align="center">
  <img src="docs/screenshots/00-app-icon-reference.png" width="128" alt="Whisper Smart icon" />
</p>

<h1 align="center">Whisper Smart</h1>

<p align="center">
  <strong>Voice-to-text for macOS, right from the menu bar.</strong><br>
  Hold a key, speak, release — your words appear wherever your cursor is.
</p>

<p align="center">
  <a href="https://github.com/itisrmk/whisper-smart/releases/latest">Download the latest release</a>
</p>

---

## How it works

1. **Hold your hotkey** (default: Right Command)
2. **Speak** — the app records from your mic
3. **Release** — transcription is injected at the cursor

Works in any app: browsers, editors, terminals, Slack, email — everywhere you type.

## Install

1. Download **Whisper-Smart-mac.dmg** from [Releases](https://github.com/itisrmk/whisper-smart/releases/latest)
2. Open the DMG and drag **Whisper Smart** into **Applications**
3. Launch — it appears as a mic icon in your menu bar
4. Grant **Accessibility** and **Microphone** permissions when prompted

> Requires macOS 14 (Sonoma) or later.

## Speech providers

Choose the provider that fits your workflow in **Settings > Provider**:

| Preset | Engine | Runs locally | Setup |
|--------|--------|:---:|-------|
| **Light** | Whisper Tiny/Base | Yes | Needs Command Line Tools |
| **Balanced** | Parakeet TDT 0.6B | Yes | One-click in-app download |
| **Best** | Whisper Large-v3 Turbo | Yes | Needs Command Line Tools |
| **Cloud** | OpenAI Whisper API | No | Paste your API key |

If the selected provider isn't ready yet, the app falls back to **Apple Speech** (built-in, zero setup) so you're never stuck.

## Features

- **Press-and-hold or one-shot** — hold the hotkey while speaking, or click "Start Dictation" from the menu for toggle mode
- **Left/right key aware** — bind specifically to Right Command without Left Command triggering it
- **Configurable hotkey** — pick a preset or record any modifier combo in Settings
- **Terminal-friendly** — special paste handling for Terminal.app, iTerm2, Kitty, Warp, Ghostty, and more
- **Smart silence detection** — if you don't speak, it returns to idle instantly instead of waiting
- **Writing styles** — neutral, formal, concise, casual, or developer mode with per-app overrides
- **Auto-updates** — built-in Sparkle updater checks for new versions automatically
- **Privacy-first** — local providers keep audio on your Mac; cloud is opt-in

## Customizing the hotkey

Open **Settings > Hotkey** to:

- **Pick a preset**: Right Command Hold, Left Control Hold, Option+Space, Control+Space, Fn Hold
- **Record a custom combo**: Click the shortcut pill and press your key combination
- **Left vs right matters**: Each physical key is tracked independently

## Building from source

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
