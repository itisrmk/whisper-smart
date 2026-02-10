# VisperflowClone — Product Specification

> macOS-native voice-to-text dictation app with AI-powered editing.
> Target: feature parity with Wispr Flow (macOS), fully local-first architecture.

---

## 1. Product Vision

VisperflowClone is a macOS menu-bar app that replaces keyboard input with voice dictation in **any** text field system-wide. It combines a local speech-to-text engine (Whisper.cpp) with LLM-based post-processing to clean, format, and transform dictated text before insertion. Unlike Wispr Flow, VisperflowClone prioritizes **on-device processing** by default, with optional cloud fallback.

### 1.1 Design Principles

| Principle | Implication |
|---|---|
| Local-first | Whisper.cpp for STT; on-device LLM (llama.cpp / MLX) for editing. Cloud is opt-in. |
| Zero-friction | Single global hotkey to start/stop. No window focus changes. |
| Universal insertion | Works in any app via macOS Accessibility API text insertion. |
| Privacy by default | Audio never leaves the device unless the user explicitly enables cloud. |

---

## 2. User Stories

### 2.1 Core Dictation

| ID | As a... | I want to... | So that... | Priority |
|---|---|---|---|---|
| US-01 | User | Press a global hotkey and start dictating | I can input text without touching the keyboard | P0 |
| US-02 | User | See my dictated text appear in the currently focused text field | I don't have to copy-paste from a separate window | P0 |
| US-03 | User | Have filler words ("um", "uh", "like") auto-removed | My text reads cleanly without manual editing | P0 |
| US-04 | User | Have punctuation auto-inserted from pauses and intonation | I don't have to say "period" or "comma" | P0 |
| US-05 | User | Correct myself mid-sentence ("at 2... actually 3") and only see the correction | Backtracking works naturally like real speech | P1 |
| US-06 | User | Dictate in whisper volume | I can use the app in quiet environments (libraries, open offices) | P1 |
| US-07 | User | Dictate in 20+ languages with auto-detection | I can switch languages without changing settings | P1 |

### 2.2 AI Editing & Commands

| ID | As a... | I want to... | So that... | Priority |
|---|---|---|---|---|
| US-10 | User | Say "make this more formal" after dictating | The AI rewrites my text in a formal tone | P0 |
| US-11 | User | Say "translate to Spanish" | Inline translation happens without leaving the app | P1 |
| US-12 | User | Say "summarize this" on selected text | I get a concise summary inserted in-place | P1 |
| US-13 | User | Say "bold the title" or "make a numbered list" | Formatting is applied via voice commands | P2 |

### 2.3 Personalization

| ID | As a... | I want to... | So that... | Priority |
|---|---|---|---|---|
| US-20 | User | Add custom words to a personal dictionary | Domain-specific jargon is recognized correctly | P0 |
| US-21 | User | Define voice snippets (e.g., "insert disclaimer" -> full text block) | Repetitive text is inserted instantly | P1 |
| US-22 | User | Set per-app writing styles (formal for email, casual for Slack) | Tone adapts automatically based on context | P2 |
| US-23 | Developer | Have camelCase, snake_case, and CLI commands transcribed accurately | Code dictation doesn't require constant corrections | P1 |

### 2.4 System Integration

| ID | As a... | I want to... | So that... | Priority |
|---|---|---|---|---|
| US-30 | User | See a menu-bar icon with recording status | I always know if the mic is active | P0 |
| US-31 | User | Configure the global hotkey in preferences | I can avoid conflicts with other apps | P0 |
| US-32 | User | See a floating mini-overlay showing real-time transcription | I get visual feedback while dictating | P1 |
| US-33 | User | Have the app auto-launch at login | I don't have to remember to start it | P2 |

---

## 3. MVP vs V2 Scope

### 3.1 MVP (v0.1 — Milestone 1-3)

**Goal**: Working dictation with AI cleanup, insertable into any text field.

- Global hotkey to record / stop (push-to-talk)
- Local Whisper.cpp STT (English, base/small model)
- Filler word removal (regex + LLM pass)
- Auto-punctuation
- Text insertion via Accessibility API (`AXUIElement`)
- Menu-bar app with recording indicator
- Floating transcription overlay (minimal)
- Personal dictionary (JSON file, manual add/remove)
- Settings pane: hotkey config, model selection, mic selection
- macOS permission request flows (Microphone, Accessibility)

### 3.2 V2 (v0.2 — Milestone 4-6)

- Command Mode (voice-driven text transformation)
- Whisper mode (low-volume recognition tuning)
- Multi-language support (auto-detection, 20+ languages)
- Backtracking / self-correction detection
- Voice snippets with trigger phrases
- Per-app style profiles
- Developer mode (syntax-aware transcription, camelCase/snake_case)
- Cloud STT fallback (OpenAI Whisper API, opt-in)
- Usage analytics dashboard (local-only, words/day, top apps)
- Auto-update mechanism (Sparkle framework)

### 3.3 V3 / Future

- Team shared dictionary & snippets (sync via iCloud or custom backend)
- iOS companion app
- On-device LLM fine-tuning on user's writing style
- Cursor/Xcode file-tagging integration
- Streaming transcription (real-time word-by-word display)

---

## 4. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   macOS Menu Bar App                 │
│                  (SwiftUI + AppKit)                  │
├──────────┬──────────┬───────────┬───────────────────┤
│ Audio    │ STT      │ AI Post-  │ Text Insertion    │
│ Capture  │ Engine   │ Processor │ Engine            │
│ (AVFound)│(whisper  │(llama.cpp │(AXUIElement /     │
│          │  .cpp)   │ or MLX)   │ CGEvent paste)    │
├──────────┴──────────┴───────────┴───────────────────┤
│                   Core Services                      │
│  ┌────────┐ ┌──────────┐ ┌────────┐ ┌────────────┐ │
│  │Hotkey  │ │Dictionary│ │Snippet │ │Preferences │ │
│  │Manager │ │Manager   │ │Engine  │ │Store       │ │
│  └────────┘ └──────────┘ └────────┘ └────────────┘ │
├─────────────────────────────────────────────────────┤
│              macOS System APIs                       │
│  Accessibility · CGEvent · AVAudioEngine · IOKit     │
└─────────────────────────────────────────────────────┘
```

### 4.1 Key Technology Choices

| Component | Technology | Rationale |
|---|---|---|
| UI Framework | SwiftUI + AppKit (hybrid) | Menu-bar apps need AppKit; overlays use SwiftUI |
| Audio Capture | AVAudioEngine | Low-latency, system mic access, VAD-ready |
| STT | whisper.cpp (C++ via Swift bridging) | Local, fast, supports multiple model sizes |
| AI Post-processing | llama.cpp / MLX | On-device LLM for filler removal, formatting, commands |
| Text Insertion | AXUIElement (Accessibility API) | Direct text field manipulation without clipboard |
| Fallback Insertion | CGEvent (Cmd+V paste) | For apps that block Accessibility |
| Global Hotkey | CGEvent tap / MASShortcut | System-wide hotkey capture |
| Persistence | UserDefaults + JSON files | Lightweight; no database needed for MVP |
| Distribution | Direct DMG + Sparkle | Outside App Store for Accessibility entitlements |

---

## 5. Permission Flows

VisperflowClone requires three macOS permissions. Each must be requested with clear user-facing rationale and graceful degradation.

### 5.1 Microphone Access

```
Trigger:  First recording attempt
API:      AVCaptureDevice.requestAccess(for: .audio)
Fallback: Show "Microphone access required" alert with
          button to open System Preferences > Privacy > Microphone
Recovery: App observes AVCaptureDevice auth status changes,
          auto-resumes when granted
```

**UX Flow:**
1. User presses hotkey for first time
2. System dialog: "VisperflowClone would like to access the microphone"
3. If denied → app shows persistent banner: "Microphone access needed. Open Settings?"
4. If granted → recording begins immediately

### 5.2 Accessibility Access

```
Trigger:  App launch (required for text insertion + hotkey)
API:      AXIsProcessTrusted() / AXIsProcessTrustedWithOptions()
Fallback: Show onboarding screen with step-by-step guide to
          System Preferences > Privacy > Accessibility
Recovery: Poll AXIsProcessTrusted() every 2s during onboarding,
          auto-proceed when granted
```

**UX Flow:**
1. App launches → checks `AXIsProcessTrusted()`
2. If untrusted → show onboarding modal with annotated screenshot
3. Modal includes "Open Accessibility Settings" button
4. App polls trust status; dismisses modal when granted
5. If still untrusted after 60s → show "paste-mode fallback" option (Cmd+V)

### 5.3 Input Monitoring (for Global Hotkey)

```
Trigger:  First hotkey registration
API:      IOHIDManager / CGEvent tap
Note:     On macOS 14+, Input Monitoring is a separate
          Privacy pane from Accessibility
Fallback: If denied, hotkey won't work. Show alert directing
          to System Preferences > Privacy > Input Monitoring
```

### 5.4 Permission State Machine

```
                    ┌─────────┐
                    │  LAUNCH  │
                    └────┬────┘
                         │
                    ┌────▼────┐
              ┌─────│ CHECK   │─────┐
              │     │ PERMS   │     │
              │     └─────────┘     │
         all granted          missing perms
              │                     │
         ┌────▼────┐          ┌────▼────┐
         │  READY  │          │ONBOARD- │
         │         │          │  ING    │
         └─────────┘          └────┬────┘
                                   │
                              user grants
                                   │
                              ┌────▼────┐
                              │  READY  │
                              └─────────┘
```

---

## 6. Risk Register

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-01 | Accessibility API rejected by macOS (notarization) | Medium | Critical | Distribute outside App Store; sign with Developer ID; provide manual Accessibility enable guide |
| R-02 | Whisper.cpp model too large for older Macs (8GB RAM) | Medium | High | Default to `tiny` or `base` model; let user upgrade to `small`/`medium` in settings; show RAM warning |
| R-03 | On-device LLM too slow for real-time editing | High | High | Use quantized models (Q4_K_M); benchmark on M1; fall back to regex-only cleanup if inference > 2s |
| R-04 | AXUIElement text insertion fails in Electron apps | Medium | Medium | Detect Electron apps; fall back to clipboard paste (Cmd+V) with auto-restore of previous clipboard |
| R-05 | Global hotkey conflicts with other apps | Low | Medium | Let user configure hotkey; detect conflicts on set; suggest alternatives |
| R-06 | Audio quality varies (built-in mic vs external) | Medium | Medium | Auto-detect mic; recommend external mic in onboarding; apply noise gate preprocessing |
| R-07 | Privacy backlash (audio processing concerns) | Medium | High | All processing local by default; no telemetry; open-source core engine; clear privacy policy |
| R-08 | macOS version fragmentation (13 vs 14 vs 15) | Medium | Medium | Target macOS 14+ (Sonoma); test on 13 (Ventura) but don't guarantee; use `@available` checks |
| R-09 | Whisper mode accuracy degradation | High | Medium | Fine-tune VAD threshold for whisper; allow user to adjust sensitivity; train with low-volume samples |
| R-10 | Command Mode misinterprets dictation as commands | Medium | High | Require explicit trigger phrase ("Hey Visper, ...") or dedicated hotkey for command mode |
| R-11 | App uses excessive CPU/battery during idle | Low | High | Stop audio engine when not recording; no background processing; use efficient polling intervals |
| R-12 | Model download fails or corrupts | Low | Medium | SHA-256 verification; resume-capable downloads; bundle `tiny` model in DMG, download larger on demand |

---

## 7. Milestone Plan

### Milestone 1 — Foundation (Weeks 1-3)

**Deliverable**: Menu-bar app skeleton with audio capture and permission flows.

| Task | Description | Est. |
|---|---|---|
| M1-01 | Xcode project setup: SwiftUI + AppKit menu-bar app | 2d |
| M1-02 | Menu-bar icon with recording state (idle/recording/processing) | 1d |
| M1-03 | Microphone permission request + fallback UI | 1d |
| M1-04 | Accessibility permission onboarding flow | 2d |
| M1-05 | AVAudioEngine capture → PCM buffer pipeline | 2d |
| M1-06 | Global hotkey registration (push-to-talk) | 2d |
| M1-07 | Settings window: mic selector, hotkey config | 2d |
| M1-08 | App auto-launch at login (LaunchAgent or LoginItem) | 1d |

### Milestone 2 — STT Integration (Weeks 4-6)

**Deliverable**: Voice → text transcription working end-to-end.

| Task | Description | Est. |
|---|---|---|
| M2-01 | Integrate whisper.cpp via Swift C bridging header | 3d |
| M2-02 | Model management: download, verify, select (tiny/base/small) | 2d |
| M2-03 | Audio buffer → whisper.cpp inference pipeline | 2d |
| M2-04 | Floating overlay: show real-time transcription result | 2d |
| M2-05 | Basic VAD (voice activity detection) to trim silence | 2d |
| M2-06 | Benchmarking: latency + accuracy on M1/M2/Intel | 1d |

### Milestone 3 — AI Post-Processing + Insertion (Weeks 7-10)

**Deliverable**: MVP — dictate, clean, and insert text into any app.

| Task | Description | Est. |
|---|---|---|
| M3-01 | Integrate llama.cpp / MLX for on-device LLM | 3d |
| M3-02 | Filler word removal pipeline (regex pre-pass + LLM refine) | 2d |
| M3-03 | Auto-punctuation via LLM | 2d |
| M3-04 | AXUIElement text insertion into focused field | 3d |
| M3-05 | Clipboard-paste fallback for incompatible apps | 1d |
| M3-06 | Personal dictionary: add/remove/import words (JSON store) | 2d |
| M3-07 | End-to-end integration testing across 10+ apps | 3d |
| M3-08 | MVP release build: sign, notarize, create DMG | 2d |

### Milestone 4 — Command Mode & Whisper Mode (Weeks 11-14)

**Deliverable**: Voice-driven text editing and low-volume dictation.

| Task | Description | Est. |
|---|---|---|
| M4-01 | Command Mode: detect trigger phrase, parse intent | 3d |
| M4-02 | Command execution: rewrite, translate, summarize, format | 3d |
| M4-03 | Whisper Mode: VAD tuning for low-volume input | 2d |
| M4-04 | Backtracking detection ("actually", "I mean", "wait") | 2d |
| M4-05 | Per-app style profiles (detect frontmost app via NSWorkspace) | 2d |

### Milestone 5 — Multi-Language & Developer Mode (Weeks 15-18)

**Deliverable**: Broad language support and code-aware dictation.

| Task | Description | Est. |
|---|---|---|
| M5-01 | Multi-language Whisper models (download on demand) | 2d |
| M5-02 | Auto language detection from audio | 2d |
| M5-03 | Developer mode: syntax-aware transcription | 3d |
| M5-04 | camelCase / snake_case / UPPER_CASE detection and formatting | 2d |
| M5-05 | Voice snippets engine: trigger phrase → text expansion | 2d |
| M5-06 | Cloud STT fallback (OpenAI Whisper API, opt-in toggle) | 2d |

### Milestone 6 — Polish & Distribution (Weeks 19-22)

**Deliverable**: Production-ready v1.0 release.

| Task | Description | Est. |
|---|---|---|
| M6-01 | Usage analytics dashboard (local SQLite, no telemetry) | 3d |
| M6-02 | Auto-update via Sparkle framework | 2d |
| M6-03 | Onboarding tutorial (first-run experience) | 2d |
| M6-04 | Performance profiling: CPU, memory, battery impact | 2d |
| M6-05 | Accessibility audit (VoiceOver support for our own UI) | 2d |
| M6-06 | Documentation: README, user guide, developer setup | 2d |
| M6-07 | Landing page and distribution pipeline | 2d |

---

## 8. Non-Functional Requirements

| Requirement | Target |
|---|---|
| Cold-start to ready | < 3 seconds |
| Hotkey-to-recording latency | < 100ms |
| STT latency (10s audio, base model) | < 2 seconds on Apple Silicon |
| Post-processing latency | < 1 second (filler removal + punctuation) |
| Memory usage (idle) | < 80 MB |
| Memory usage (recording + inference) | < 500 MB |
| CPU usage (idle) | < 1% |
| Supported macOS versions | 14.0+ (Sonoma) |
| Supported architectures | arm64 (Apple Silicon), x86_64 (Intel, best-effort) |
| Audio format | 16kHz, 16-bit, mono PCM (Whisper requirement) |

---

## 9. Data Model

### 9.1 User Dictionary

```json
{
  "version": 1,
  "words": [
    { "word": "Supabase", "context": "tech", "added": "2025-01-15T10:00:00Z" },
    { "word": "Vercel", "context": "tech", "added": "2025-01-15T10:00:00Z" }
  ]
}
```

**Storage**: `~/Library/Application Support/VisperflowClone/dictionary.json`

### 9.2 Voice Snippets

```json
{
  "version": 1,
  "snippets": [
    {
      "trigger": "insert disclaimer",
      "content": "This is not legal advice. Consult a qualified attorney.",
      "created": "2025-01-15T10:00:00Z"
    }
  ]
}
```

**Storage**: `~/Library/Application Support/VisperflowClone/snippets.json`

### 9.3 App Preferences

```swift
// UserDefaults keys
enum PrefKey: String {
    case globalHotkey          // e.g., "Option+Space"
    case selectedMic           // AVCaptureDevice uniqueID
    case whisperModel          // "tiny" | "base" | "small" | "medium"
    case enableWhisperMode     // Bool
    case enableCommandMode     // Bool
    case cloudFallbackEnabled  // Bool (default: false)
    case autoLaunchAtLogin     // Bool
    case overlayPosition       // "topRight" | "bottomRight" | "cursor"
    case developerModeEnabled  // Bool
}
```

### 9.4 Style Profiles

```json
{
  "version": 1,
  "profiles": [
    {
      "appBundleId": "com.apple.mail",
      "style": "formal",
      "prompt": "Rewrite to be professional and concise."
    },
    {
      "appBundleId": "com.tinyspeck.slackmacgap",
      "style": "casual",
      "prompt": "Keep it casual and friendly. Use contractions."
    }
  ]
}
```

**Storage**: `~/Library/Application Support/VisperflowClone/styles.json`

---

## 10. Testing Strategy

| Layer | Approach |
|---|---|
| Unit tests | XCTest: dictionary manager, snippet engine, filler removal regex, preference store |
| Integration tests | Audio pipeline: recorded WAV → whisper.cpp → post-processor → expected text |
| UI tests | XCUITest: onboarding flow, settings pane, overlay appearance |
| App compatibility | Manual testing matrix: Mail, Slack, Notion, Chrome, Safari, VS Code, Cursor, Terminal, Xcode |
| Performance tests | XCTest `measure {}` blocks for STT latency, LLM inference, text insertion |
| Accessibility tests | VoiceOver navigation of all UI elements |

---

## Appendix A: Glossary

| Term | Definition |
|---|---|
| STT | Speech-to-Text — converting audio to text |
| VAD | Voice Activity Detection — detecting when someone is speaking |
| AXUIElement | macOS Accessibility API for reading/writing UI elements |
| CGEvent | macOS Core Graphics event system (keyboard/mouse simulation) |
| Push-to-talk | Hold hotkey to record, release to stop |
| Command Mode | Voice commands that transform text rather than insert it |
| Whisper Mode | Low-volume dictation for quiet environments |
