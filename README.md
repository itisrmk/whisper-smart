# Whisper Smart (macOS)

Whisper Smart is a lightweight macOS menu-bar dictation app that supports local speech-to-text workflows.

## Smart model presets

In **Settings → Provider**, the app now includes explicit model presets:
- **Light**: Whisper Tiny/Base (local, fastest setup)
- **Balanced**: Parakeet TDT 0.6B v3 ONNX source (experimental)
- **Best**: Whisper Large-v3 Turbo (local quality-focused)
- **Cloud**: OpenAI Whisper API

If the selected provider is missing runtime/model files, the app degrades gracefully to Apple Speech and shows direct install/download actions in the same settings screen.

Whisper and Parakeet setup is managed in-app (runtime + model downloads), but host prerequisites still apply: Apple Command Line Tools are required for local builds, `make` is required for Whisper runtime build, and Python 3 with `venv` support is required for Parakeet runtime bootstrap. The app now fails fast with actionable guidance when these are missing.

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

## Verification

```bash
bash scripts/run_qa_smoke.sh
bash scripts/typecheck.sh
bash scripts/swift_test_check.sh
```

`swift_test_check.sh` intentionally skips `swift test` when no SwiftPM tests exist under `Tests/` and reports that decision explicitly to avoid false failures.

## Notes

For broad public distribution, use Apple Developer ID signing + notarization to avoid Gatekeeper warnings.
