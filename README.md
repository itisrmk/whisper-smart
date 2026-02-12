# Whisper Smart (macOS)

Whisper Smart is a lightweight macOS menu-bar dictation app that supports local speech-to-text workflows.

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
