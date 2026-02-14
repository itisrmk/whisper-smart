# VisperflowClone — Feature Parity Matrix

> Comparison: Wispr Flow (reference product) vs VisperflowClone (MVP / V2 / V3).
> Status key: **Yes** = implemented, **No** = not planned, **Partial** = subset, **Planned** = on roadmap.

---

## 1. Core Dictation

| Feature | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| Global hotkey (push-to-talk) | Yes | Yes | Yes | Yes | MVP: Option+Space default |
| System-wide text insertion | Yes | Yes | Yes | Yes | AXUIElement + clipboard fallback |
| Filler word removal (um, uh, like) | Yes | Yes | Yes | Yes | MVP: regex + LLM hybrid |
| Auto-punctuation | Yes | Yes | Yes | Yes | LLM-based from pauses/context |
| Backtracking / self-correction | Yes | No | Yes | Yes | V2: detect "actually", "I mean" |
| Whisper Mode (low-volume) | Yes | No | Yes | Yes | V2: VAD sensitivity tuning |
| Real-time streaming transcription | Yes | No | No | Planned | V3: word-by-word display |
| Numbered list detection | Yes | No | Yes | Yes | V2: auto-format from speech |

---

## 2. AI Post-Processing

| Feature | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| AI text cleanup (grammar, flow) | Yes | Yes | Yes | Yes | On-device LLM (llama.cpp / MLX) |
| Command Mode (voice editing) | Yes (Pro) | No | Yes | Yes | V2: "make formal", "summarize" |
| Tone rewriting | Yes (Pro) | No | Yes | Yes | V2: via Command Mode |
| Translation via voice | Yes (Pro) | No | Yes | Yes | V2: "translate to Spanish" |
| Text summarization | Yes (Pro) | No | Yes | Yes | V2: "summarize this" |
| Formatting commands (bold, list) | Yes (Pro) | No | Partial | Yes | V2: lists; V3: rich formatting |
| Context-aware name spelling | Yes | No | Yes | Yes | V2: dictionary + LLM context |

---

## 3. Language Support

| Feature | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| English dictation | Yes | Yes | Yes | Yes | MVP: primary language |
| Multi-language (100+) | Yes | No | Yes (20+) | Yes (50+) | V2: top 20 languages |
| Auto language detection | Yes | No | Yes | Yes | V2: Whisper language ID |
| Mid-sentence language switch | Yes | No | No | Planned | V3: seamless switching |
| Language-specific punctuation | Yes | No | Partial | Yes | V2: basic; V3: full rules |

---

## 4. Personalization

| Feature | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| Personal dictionary | Yes | Yes | Yes | Yes | MVP: JSON-backed word list |
| Voice snippets / shortcuts | Yes | No | Yes | Yes | V2: trigger → text expansion |
| Per-app writing styles | Yes | No | Yes | Yes | V2: bundle ID → style profile |
| Dictionary import/export | Yes | No | Yes | Yes | V2: CSV/JSON import |
| Writing style learning | Yes | No | No | Planned | V3: fine-tune on user corpus |

---

## 5. Developer Features

| Feature | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| camelCase / snake_case awareness | Yes | No | Yes | Yes | V2: code identifier formatting |
| CLI command transcription | Yes | No | Yes | Yes | V2: syntax-aware mode |
| Developer jargon recognition | Yes | Partial | Yes | Yes | MVP: via dictionary; V2: built-in |
| File tagging (Cursor/Windsurf) | Yes | No | No | Planned | V3: IDE integration |
| Code block detection | Yes | No | No | Yes | V3: auto-wrap in backticks |

---

## 6. System Integration

| Feature | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| Menu-bar app | Yes | Yes | Yes | Yes | MVP: AppKit status item |
| Recording status indicator | Yes | Yes | Yes | Yes | MVP: icon state changes |
| Floating transcription overlay | Yes | Yes | Yes | Yes | MVP: minimal; V2: configurable |
| Settings / preferences pane | Yes | Yes | Yes | Yes | MVP: hotkey, mic, model; now includes Smart presets (Light/Balanced/Best/Cloud) with in-app download actions |
| Auto-launch at login | Yes | Yes | Yes | Yes | MVP: LoginItem API |
| Auto-update | Yes | No | Yes | Yes | V2: Sparkle framework |
| Onboarding tutorial | Yes | No | Yes | Yes | V2: first-run experience |

---

## 7. Privacy & Processing

| Feature | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| Cloud-based STT | Yes (default) | No | Opt-in | Opt-in | **Key differentiator**: local-first |
| On-device STT | No | Yes | Yes | Yes | whisper.cpp, always available |
| On-device AI editing | No | Yes | Yes | Yes | llama.cpp / MLX |
| No telemetry by default | No | Yes | Yes | Yes | Opt-in analytics only |
| Audio stays on device | No (default) | Yes | Yes | Yes | Unless cloud fallback enabled |
| Open-source engine | No | Yes | Yes | Yes | Core STT/LLM pipeline |

---

## 8. Platform Support

| Platform | Wispr Flow | VC MVP | VC V2 | VC V3 | Notes |
|---|---|---|---|---|---|
| macOS (Apple Silicon) | Yes | Yes | Yes | Yes | Primary target |
| macOS (Intel) | Yes | Partial | Yes | Yes | MVP: best-effort, slower inference |
| Windows | Yes | No | No | No | Out of scope |
| iOS | Yes | No | No | Planned | V3: companion app |
| Android | Waitlist | No | No | No | Out of scope |

---

## 9. Pricing Model Comparison

| Aspect | Wispr Flow | VisperflowClone |
|---|---|---|
| Free tier | 2,000 words/week | Unlimited (on-device) |
| Pro tier | $15/month | N/A (open-source core) |
| Cloud features | Included in Pro | Pay-your-own-API-key |
| Team features | Enterprise plan | V3: iCloud sync |
| Student pricing | $10/month | Free |

---

## 10. Permissions Required

| Permission | Wispr Flow | VC MVP | Purpose |
|---|---|---|---|
| Microphone | Yes | Yes | Audio capture for dictation |
| Accessibility | Yes | Yes | Text insertion into any app, frontmost app detection |
| Input Monitoring | Yes | Yes | Global hotkey capture (macOS 14+) |
| Network (outbound) | Yes | No (MVP) | MVP: fully offline. V2: optional cloud fallback |
| Full Disk Access | No | No | Not required |

---

## 11. App Compatibility Matrix

> Apps tested for text insertion compatibility. Primary insertion method: AXUIElement. Fallback: clipboard paste.

| Application | Category | AX Insert | Clipboard Fallback | Test Priority |
|---|---|---|---|---|
| Apple Mail | Email | Expected | Backup | P0 |
| Gmail (Chrome) | Email | Likely No | Primary | P0 |
| Gmail (Safari) | Email | Likely No | Primary | P0 |
| Slack (native) | Messaging | Expected | Backup | P0 |
| Slack (browser) | Messaging | Likely No | Primary | P1 |
| iMessage | Messaging | Expected | Backup | P0 |
| WhatsApp (native) | Messaging | Expected | Backup | P1 |
| Notion (native) | Docs | Uncertain | Primary | P0 |
| Google Docs (browser) | Docs | Likely No | Primary | P0 |
| VS Code | IDE | Expected | Backup | P0 |
| Cursor | IDE | Expected | Backup | P0 |
| Xcode | IDE | Expected | Backup | P1 |
| Terminal | CLI | Expected | Backup | P1 |
| iTerm2 | CLI | Expected | Backup | P1 |
| Safari address bar | Browser | Expected | Backup | P1 |
| Chrome address bar | Browser | Likely No | Primary | P1 |
| Notes | Notes | Expected | Backup | P1 |
| TextEdit | Editor | Expected | Backup | P2 |
| Spotlight | System | Uncertain | Backup | P2 |

---

## 12. Model Size & Performance Matrix

> Whisper.cpp model variants and expected performance on different hardware.

| Model | Size (disk) | RAM Usage | M1 Speed (10s audio) | M2 Speed | Intel i7 Speed | Accuracy (WER) |
|---|---|---|---|---|---|---|
| tiny | 75 MB | ~200 MB | ~0.5s | ~0.3s | ~1.5s | ~12% |
| base | 142 MB | ~350 MB | ~1.0s | ~0.7s | ~3.0s | ~9% |
| small | 466 MB | ~800 MB | ~2.5s | ~1.5s | ~8.0s | ~7% |
| medium | 1.5 GB | ~2.5 GB | ~7.0s | ~4.0s | ~25s | ~5% |
| large-v3 | 3.1 GB | ~4.5 GB | ~15s | ~9.0s | N/A | ~4% |

**MVP default**: `base` on Apple Silicon, `tiny` on Intel.
**Recommendation**: Let users choose in Settings; show estimated speed for their hardware.

---

## 13. Feature Implementation Dependency Graph

```
                    ┌────────────────┐
                    │  Audio Capture  │  M1
                    │  (AVAudioEngine)│
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │  whisper.cpp   │  M2
                    │  STT Engine    │
                    └───────┬────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
      ┌───────▼──────┐ ┌───▼───────┐ ┌──▼──────────┐
      │ Filler Remove│ │ Auto-Punct│ │ Dictionary  │  M3
      │ (LLM)       │ │ (LLM)     │ │ Lookup      │
      └───────┬──────┘ └───┬───────┘ └──┬──────────┘
              │             │            │
              └─────────────┼────────────┘
                            │
                    ┌───────▼────────┐
                    │ Text Insertion │  M3
                    │ (AXUIElement)  │
                    └───────┬────────┘
                            │
          ┌─────────────────┼──────────────────┐
          │                 │                  │
  ┌───────▼──────┐  ┌──────▼───────┐  ┌──────▼───────┐
  │ Command Mode │  │ Whisper Mode │  │ Backtracking │  M4
  │              │  │              │  │              │
  └──────────────┘  └──────────────┘  └──────────────┘
          │
  ┌───────▼──────┐  ┌──────────────┐  ┌──────────────┐
  │ Multi-lang   │  │ Dev Mode     │  │ Snippets     │  M5
  │              │  │              │  │              │
  └──────────────┘  └──────────────┘  └──────────────┘
          │
  ┌───────▼──────┐  ┌──────────────┐
  │ Analytics    │  │ Auto-Update  │  M6
  │              │  │              │
  └──────────────┘  └──────────────┘
```

---

## 14. Competitive Positioning Summary

| Dimension | Wispr Flow | VisperflowClone | Advantage |
|---|---|---|---|
| Processing | Cloud (OpenAI, Meta) | On-device (Whisper.cpp, llama.cpp) | VC: Privacy, no subscription |
| Latency | Low (server GPUs) | Medium (local inference) | WF: Faster on complex tasks |
| Accuracy | High (large cloud models) | Good (small local models) | WF: Higher accuracy ceiling |
| Cost | $15/month | Free (open-source) | VC: No recurring cost |
| Privacy | Audio sent to cloud | Audio stays on device | VC: Full privacy |
| Offline | No | Yes | VC: Works without internet |
| Platforms | Mac, Win, iOS | macOS only (MVP) | WF: Broader reach |
| Team features | Yes (Enterprise) | No (MVP) | WF: Collaboration |
| Open source | No | Yes (core engine) | VC: Extensible, auditable |
