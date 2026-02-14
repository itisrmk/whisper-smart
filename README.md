# Whisper Smart (macOS)

Whisper Smart is a lightweight macOS menu-bar dictation app that supports local speech-to-text workflows.

## Smart model presets

In **Settings → Provider**, the app now includes explicit model presets:
- **Light**: Whisper Tiny/Base (local, fastest setup)
- **Balanced**: Parakeet CTC 0.6B (local)
- **Best**: Whisper Large-v3 Turbo (local quality-focused)
- **Cloud**: OpenAI Whisper API

If the selected provider is missing runtime/model files, the app degrades gracefully to Apple Speech and shows direct install/download actions in the same settings screen.

## App icon

![Whisper Smart app icon](docs/screenshots/00-app-icon-reference.png)

## Download

- Grab the latest DMG from **GitHub Releases**.
- Open the DMG and drag **Whisper Smart.app** into **Applications**.

```bash
bash scripts/package_dmg.sh
```

Output:

- `.build/release/Whisper-Smart-mac.dmg`

## Notes

For broad public distribution, use Apple Developer ID signing + notarization to avoid Gatekeeper warnings.
