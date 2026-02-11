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
| `VFColor.glass0` – `glass3` | Layered dark surfaces (0.06 → 0.18 white) |
| `VFColor.glassBorder` | 1-px white-8% separator between glass layers |
| `VFColor.glassHighlight` | White-12% top-edge shine on cards |
| `VFColor.depthRadialTop` | Cool blue-grey radial tint for background depth |
| `VFColor.depthRadialBottom` | Warm purple radial tint for background depth |
| `VFColor.textTertiary` | White-35% for captions and hints |
| `VFColor.accentGradient` | Blue-to-purple brand gradient |
| `VFColor.*Gradient` | Per-state two-stop vertical gradients |

### Typography

Use `VFFont.*` presets. All fonts use the system `.rounded` design for
the bubble status label, and the default design elsewhere. Sizes:

- Bubble status: 11pt medium rounded
- Menu items: 13pt regular
- Settings heading: 20pt bold rounded
- Settings title: 15pt semibold rounded
- Settings body/caption: 13pt / 11pt regular
- Pill label: 12pt medium rounded
- Segment label: 13pt medium rounded

### Spacing

A 4-point grid: `xxs(2) xs(4) sm(8) md(12) lg(16) xl(24) xxl(32)`.

### Animation

| Token | Description |
|---|---|
| `springSnappy` | Quick spring for state transitions |
| `springGentle` | Softer spring for larger movements |
| `springBounce` | Bouncy spring for interactive feedback |
| `fadeFast / fadeMedium` | Opacity crossfades |
| `pulseLoop` | Infinite breathing pulse for listening ring |
| `glowPulse` | Slow breathing for ambient glow (1.6s) |
| `shimmer` | Continuous linear loop for sheen effects |

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

The settings window uses a custom glass segmented tab bar (not the
native `TabView`) with three tabs:

1. **General** — Launch at login, show/hide bubble. Uses `GlassToggleRow`
   with pill toggles inside a `GlassSection` card.
2. **Hotkey** — Shortcut preset picker with pill badge and dropdown.
3. **Provider** — Glass pill dropdown for transcription provider
   selection. Lists Whisper (local), OpenAI API, Deepgram, AssemblyAI.

The window forces dark appearance (`NSAppearance.darkAqua`) and
`fullSizeContentView` with transparent titlebar so the `glass0`
background runs edge-to-edge.

Settings persist via `@AppStorage` for general toggles.

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

---

## 7. iOS-inspired dark glass theme

The visual language draws from iOS-style dark glassmorphism while
staying macOS-native.

### Layered dark surfaces

Four tonal steps (`glass0` – `glass3`) create perceived depth without
translucency blur. Each step is a solid dark grey; higher numbers are
brighter:

| Layer | White value | Role |
|---|---|---|
| `glass0` | 6% | Window / deepest background |
| `glass1` | 10% | Card fill |
| `glass2` | 14% | Elevated card / hover / selected segment |
| `glass3` | 18% | Pill control fill, input backgrounds |

### Container / background treatment

Use `.layeredDepthBackground()` on any root container instead of a
flat `glass0` fill. The modifier composites three layers:

1. **Solid base** — `glass0` (6% white).
2. **Radial depth tints** — Two faint radial gradients:
   - Cool blue-grey (`depthRadialTop`, 12% opacity) from top-leading.
   - Warm purple (`depthRadialBottom`, 8% opacity) from bottom-trailing.
   They provide subtle environmental depth without competing with
   content.
3. **Film grain overlay** — A procedural `GrainTexture` rendered via
   SwiftUI `Canvas` (no image asset). Deterministic hash-based noise
   at 4% opacity / 3-pt cells. Adds tactile texture to flat dark
   surfaces while preserving text readability.

The `SettingsView` and bubble preview both use this treatment.

### Glass card treatment

The reusable `.glassCard()` modifier applies:

1. **Gradient fill** — A subtle top-to-bottom gradient from `fillColor`
   (default `glass1`) at full opacity to 85%, creating a slight
   vertical lift.
2. **Border** — 1-px `glassBorder` (white 8%).
3. **Multi-stop top-edge highlight** — A stroke gradient with three
   stops: 18% white at the top, fading through 6% at 30%, to clear
   at 55%. This produces a more realistic lit-from-above shine than
   a two-stop fade.
4. **Depth shadow** — `VFShadow.cardColor` at 16-pt radius, offset
   6-pt down.

For additional inner-edge highlights on custom shapes, use the
`.innerHighlight(cornerRadius:)` modifier which applies an inset
`strokeBorder` with the same multi-stop gradient.

### Accent gradients & glow

Each bubble state has a two-stop vertical gradient (`*Gradient`).
The floating bubble adds an outer glow circle (`tintColor` at 15–35%
opacity, blurred 20-pt) that breathes with `glowPulse` during
`listening`.

### Pill controls

Interactive controls — toggles, shortcut badges, provider dropdown —
use fully-rounded capsule shapes with `glass3` fill and `glassBorder`
stroke. The custom `GlassPillToggle` mimics the iOS toggle with a
white knob, accent fill when on, and `springSnappy` animation.

### Segmented tab bar

`GlassSegmentedControl` replaces the native `TabView` tabs.
It is a `glass1` pill containing items; the selected item slides a
`glass2` rounded-rect indicator using `matchedGeometryEffect` and
`springSnappy` animation.

### Typography

Headings and labels use SF Pro Rounded (`.design(.rounded)`) at
heavier weights. Body text uses the default system design for
readability. A three-tier text colour hierarchy
(`textPrimary` / `textSecondary` / `textTertiary`) ensures WCAG-AA
contrast on the dark glass surfaces.

### Accessibility

- `textPrimary` (white) on `glass0` (6% white) yields ~18:1 contrast.
- `textSecondary` (55% white) on `glass0` yields ~9:1 contrast.
- `textTertiary` (35% white) on `glass0` yields ~5.5:1, used for
  hints only where AA-large (3:1) suffices.
- Pill toggles include a visible state difference (accent vs grey fill)
  plus a positional knob indicator, so colour is not the only cue.
