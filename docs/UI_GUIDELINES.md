# Visperflow UI Guidelines

This document describes the design language, component architecture, and
conventions for the Visperflow menu-bar dictation app UI shell.

---

## 1. Design Tokens

All magic numbers live in `app/UI/DesignTokens.swift`. Import the
token enums (`VFColor`, `VFFont`, `VFSpacing`, `VFRadius`, `VFSize`,
`VFAnimation`) instead of hard-coding values.

### Colors

| Token | Usage |
|---|---|
| `VFColor.accentFallback` | Primary brand blue `#4A90FF` |
| `VFColor.listening` | Blue — active listening state |
| `VFColor.transcribing` | Purple — processing audio |
| `VFColor.success` | Green — transcription complete |
| `VFColor.error` | Red — failure state |
| `VFColor.surfaceOverlay` | Semi-transparent black for floating chrome |
| `VFColor.textOnOverlay` | White text on dark overlays |

### Typography

Use `VFFont.*` presets. All fonts use the system `.rounded` design for
the bubble status label, and the default design elsewhere. Sizes:

- Bubble status: 11pt medium rounded
- Menu items: 13pt regular
- Settings title: 15pt semibold
- Settings body/caption: 13pt / 11pt regular

### Spacing

A 4-point grid: `xxs(2) xs(4) sm(8) md(12) lg(16) xl(24) xxl(32)`.

### Animation

| Token | Description |
|---|---|
| `springSnappy` | Quick spring for state transitions |
| `springGentle` | Softer spring for larger movements |
| `fadeFast / fadeMedium` | Opacity crossfades |
| `pulseLoop` | Infinite breathing pulse for listening ring |

---

## 2. Component Architecture

```
app/
├── App/
│   ├── main.swift               # NSApplication entry point
│   └── AppDelegate.swift        # Wires UI controllers together
├── UI/
│   ├── DesignTokens.swift       # Color, font, spacing, animation tokens
│   ├── BubbleState.swift        # Enum of 5 bubble states
│   ├── FloatingBubbleView.swift # SwiftUI bubble + label
│   ├── BubblePanelController.swift  # NSPanel host for bubble
│   ├── MenuBarController.swift  # NSStatusItem menu bar icon
│   ├── SettingsView.swift       # Tabbed settings (SwiftUI)
│   └── SettingsWindowController.swift # NSWindow host for settings
└── Core/                        # (reserved for audio/transcription)
```

### Ownership Flow

```
AppDelegate
  ├── MenuBarController  (owns NSStatusItem)
  ├── BubblePanelController (owns NSPanel → FloatingBubbleView)
  ├── SettingsWindowController (owns NSWindow → SettingsView)
  └── BubbleStateSubject (shared observable state)
```

`AppDelegate` is the sole owner. It passes `BubbleStateSubject` to both
the menu bar and bubble controllers so they stay in sync. The core layer
will later drive `BubbleStateSubject.transition(to:)` to update the UI.

---

## 3. Bubble States

| State | Icon | Color | Behaviour |
|---|---|---|---|
| `idle` | `mic.fill` | Blue | Static; tap to start |
| `listening` | `waveform` | Blue | Pulsing ring animation |
| `transcribing` | `text.cursor` | Purple | Static spinner feel |
| `success` | `checkmark` | Green | Auto-returns to idle |
| `error` | `exclamationmark.triangle.fill` | Red | Tap to retry |

Transitions are animated with `springSnappy`. The pulsing ring uses
`pulseLoop` and only appears during `listening`.

---

## 4. Settings Window

The settings window uses a native `TabView` with three tabs:

1. **General** — Launch at login, show/hide bubble.
2. **Hotkey** — Placeholder for a key-recording control. Currently
   displays a static `⌥ Space` badge.
3. **Provider** — Placeholder dropdown for transcription provider
   selection. Lists Whisper (local), OpenAI API, Deepgram, AssemblyAI.

Settings persist via `@AppStorage` for general toggles. Provider and
hotkey persistence will be added when the core layer is connected.

---

## 5. Conventions

- **No Dock icon.** The app uses `.accessory` activation policy.
- **Non-activating panel.** The bubble never steals keyboard focus.
- **Movable bubble.** The panel has `isMovableByWindowBackground = true`.
- **Single settings window.** `SettingsWindowController` reuses the same
  window instance.
- **SF Symbols only.** All icons use system SF Symbols — no custom
  image assets.
- **Dark-mode ready.** Semantic colors from `NSColor` adapt
  automatically. The overlay surface and bubble use explicit colors that
  work on any background.

---

## 6. Adding New UI

1. Define any new colors/fonts/spacings in `DesignTokens.swift`.
2. Build the SwiftUI view under `app/UI/`.
3. If it needs its own window, create a `*WindowController.swift`
   following the `SettingsWindowController` pattern.
4. Wire it into `AppDelegate` via a callback or direct reference.
5. Do **not** put business logic in UI files — that belongs in
   `app/Core/`.
