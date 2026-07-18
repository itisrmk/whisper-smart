# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Whisper Smart is a macOS menu-bar dictation app. Hold a hotkey, speak, release — transcribed text is injected at the cursor. Built with Swift/SwiftUI, runs as a `.accessory` (no dock icon) menu-bar app targeting macOS 14+.

## Build & Run

```bash
swift build                        # Debug build
swift build -c release             # Release build
.build/debug/Whisper\ Smart        # Run debug binary
```

## Test

```bash
bash scripts/run_qa_smoke.sh       # Smoke tests (state machine, providers, model downloads, API keys)
bash scripts/typecheck.sh          # Type-check only (no execution)
```

Smoke tests use London School mocking (MockHotkeyMonitor, MockAudioCapture, MockSTTProvider, MockInjector) in `tests/smoke/qa_smoke.swift`. They compile against the App target sources — no XCTest framework.

## Release

```bash
VERSION=X.Y.Z ALLOW_ADHOC_SIGNING=1 bash scripts/package_dmg.sh   # Build app bundle + DMG
```

Full release flow: build DMG → update `appcast.xml` (add new `<item>` at top) → commit → `git tag vX.Y.Z` → push tag + main → `gh release create` with DMG + appcast assets.

The CI workflow `.github/workflows/release-dmg.yml` handles this with proper code signing when triggered manually.

## Architecture

### Core Pipeline

```
HotkeyMonitor → DictationStateMachine → AudioCaptureService → STTProvider → ClipboardInjector
     ↕                    ↕                                                       ↕
  CGEvent tap     State: idle → recording → transcribing → success → idle    AX insert or ⌘V paste
```

**AppDelegate** (`app/App/AppDelegate.swift`) owns everything — creates all dependencies, wires callbacks, handles permission retry logic, and bridges state machine events to the UI layer.

**DictationStateMachine** (`app/Core/DictationStateMachine.swift`) is the central coordinator. All state transitions flow through it. Key design rules:
- `onStateChange` callback drives all UI updates
- Providers are hot-swappable via `replaceProvider()` — atomically resets to `.idle`
- Stale provider callbacks are guarded by identity check (`self.sttProvider === provider`)
- One-shot mode (menu click) vs hold mode (hotkey) share the same state machine
- Silent recordings (no speech detected) skip transcription and return to idle immediately

### STT Provider Abstraction

```swift
protocol STTProvider: AnyObject {
    func beginSession() throws
    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime)
    func endSession()
    var onResult: ((STTResult) -> Void)? { get set }
    var onError: ((STTError) -> Void)? { get set }
    var transcriptionTimeout: TimeInterval { get }
}
```

Implementations: `AppleSpeechSTTProvider` (built-in fallback), `MLXSTTProvider` (local Parakeet + Whisper via MLX — keeps a resident `scripts/mlx_stt_infer.py --serve` daemon in an app-managed Python venv; the model loads once, requests go over stdin/stdout JSONL, and the daemon is prewarmed at provider init), `OpenAIWhisperAPISTTProvider` (cloud). Model catalog and selection live in `MLXModelCatalog.swift`; model installs in `MLXModelInstaller.swift`; the Python runtime bootstrap (venv + pip install parakeet-mlx/mlx-whisper) in `MLXRuntimeBootstrapManager.swift`. Provider selection and fallback logic lives in `STTProviderKind.swift` / `STTProviderDiagnostics.swift`. Local MLX providers require Apple Silicon.

### Text Injection

`ClipboardInjector` tries two strategies in order:
1. **Accessibility (AX)** — directly sets `AXValue` on the focused text element (works for standard Cocoa controls)
2. **Pasteboard fallback** — copies to clipboard, synthesizes ⌘V via CGEvent, then restores original clipboard

Terminal apps (Terminal.app, iTerm2, Kitty, Warp, Ghostty, etc.) are detected by bundle ID and use longer paste/restore delays because PTY-based input processes paste events asynchronously.

### Hotkey Monitoring

`HotkeyMonitor` installs a `CGEvent` tap (requires Accessibility permission). It uses **device-dependent modifier flags** (`NX_DEVICELCMDKEYMASK` vs `NX_DEVICERCMDKEYMASK`) to distinguish left from right physical keys. Bindings are persisted as JSON in UserDefaults.

Self-healing: if the event tap fails, `AppDelegate.ensureHotkeyMonitorReady()` retries with exponential backoff (2.5s → 30s cap). The retry only clears `pendingHotkeyBootstrap` if `hotkeyMonitor.isRunning` is actually true after activation — this prevents a race condition where synchronous `onStartFailed` gets overwritten.

### UI Layer

- **MenuBarController** — NSStatusItem with mic icon, dictation toggle, recovery items
- **BubblePanelController** / **FloatingBubbleView** — floating overlay during recording
- **TopCenterOverlayPanelController** — waveform bar overlay option
- **SettingsView** (SwiftUI, `app/UI/SettingsView.swift`) — tabs: General, Hotkey, Provider, History
- **BubbleStateSubject** — ObservableObject bridging `DictationStateMachine.State` → SwiftUI

State mapping: `.idle`→`.idle`, `.recording`→`.listening`, `.transcribing`→`.transcribing`, `.success`→`.success`, `.error`→`.error`

### Design Tokens

All colors, fonts, spacing, and animation values are centralized in `app/UI/DesignTokens.swift`. Prefixed with `VF` (VFColor, VFFont, VFSpacing, VFSize, VFAnimation).

## Key Files

| File | Purpose |
|------|---------|
| `app/App/AppDelegate.swift` | App lifecycle, dependency wiring, permission retry |
| `app/Core/DictationStateMachine.swift` | Central state machine (idle/recording/transcribing/success/error) |
| `app/Core/HotkeyMonitor.swift` | CGEvent tap, press-and-hold detection, left/right key distinction |
| `app/Core/HotkeyBinding.swift` | Key binding model, presets, UserDefaults persistence |
| `app/Core/ClipboardInjector.swift` | AX insertion + pasteboard fallback, terminal-aware |
| `app/Core/AudioCaptureService.swift` | PCM audio capture, device switching, interruption handling |
| `app/Core/STTProviderKind.swift` | Provider selection, fallback resolution |
| `app/Core/DictationWorkflowSettings.swift` | User preferences (insertion mode, writing style, silence timeout) |
| `app/Core/PermissionDiagnostics.swift` | Accessibility/Microphone/Speech permission checks |
| `app/UI/SettingsView.swift` | All settings tabs (large file ~2200 lines) |
| `app/UI/DesignTokens.swift` | Design system constants |
| `scripts/build_release_app.sh` | Release binary + .app bundle + code signing |
| `scripts/package_dmg.sh` | DMG creation from .app bundle |

## Notification-Based Communication

Settings changes are communicated to AppDelegate via `NotificationCenter`:
- `.hotkeyBindingDidChange` — hotkey recorder applies new binding
- `.sttProviderDidChange` — provider picker triggers provider swap
- `.mlxRuntimeBootstrapDidChange` — Python runtime status updates
- `.mlxModelInstallDidChange` — MLX model install/uninstall events
- `.modelDownloadDidChange` — model download progress/completion
- `.transcriptLogReinsertRequested` — history re-inject action

## Important Patterns

- **Permission flow at launch**: Permissions are requested first (dialog appears), then hotkey bootstrap runs. Returning users with existing accessibility skip the dialog and get immediate hotkey activation.
- **Provider hot-swap safety**: `replaceProvider()` guards against in-flight sessions — stops audio, ends STT session, clears stale callbacks, then wires new provider.
- **Pasteboard snapshot/restore**: `ClipboardInjector` captures the full pasteboard state before injection and restores it afterward (guarded by `changeCount` to avoid clobbering user copies).
- **Speech detection threshold**: Audio level ≥ 0.08 counts as speech. If no speech detected during recording, transcription is skipped entirely.
- **Bundle ID is immutable**: `build_release_app.sh` refuses to build if `BUNDLE_ID` differs from `com.whispersmart.desktop` — changing it resets macOS TCC permission grants.

## File Organization

- `app/App/` — Entry point, AppDelegate, UpdateManager
- `app/Core/` — State machine, providers, audio, injection, settings, permissions
- `app/UI/` — SwiftUI views, AppKit controllers, design tokens
- `scripts/` — Build, test, release automation
- `tests/smoke/` — Functional smoke tests
- `docs/` — Architecture docs, product spec, UI guidelines
