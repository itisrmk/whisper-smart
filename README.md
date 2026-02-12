# Whisper Smart (macOS)

Whisper Smart is a lightweight macOS menu-bar dictation app that supports local speech-to-text workflows.

## Download

- Grab the latest DMG from **GitHub Releases**.
- Open the DMG and drag **Whisper Smart.app** into **Applications**.

## Screenshots

### DMG install window
![DMG install window](docs/screenshots/01-dmg-window.png)

### App bundle in Finder
![App bundle in Finder](docs/screenshots/02-app-bundle-finder.png)

### DMG in Finder
![DMG in Finder](docs/screenshots/03-dmg-in-finder.png)

## Build a DMG locally

```bash
bash scripts/package_dmg.sh
```

Output:

- `.build/release/Whisper-Smart-mac.dmg`

## Notes

For broad public distribution, use Apple Developer ID signing + notarization to avoid Gatekeeper warnings.
