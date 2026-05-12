---
proposal: in-recording-questions
companion: requirements.md
visual-baseline: ../../docs/design/mockups/popover-redesign.html
revised: 2026-05-12
---

# Wireframes — In-Recording Q&A + Save Transcript

These sketches accompany `requirements.md`. **Every wireframe in this document is drawn as an overlay on top of the popover redesign mockup at `docs/design/mockups/popover-redesign.html`** — they show how new surfaces (the Ask overlay, the docked pill, the timeline strip, the Save Transcript dialog, the saved-confirmation toast) attach to and re-use the popover's frame chrome, palette, typography, and row primitives. Open the baseline mockup side-by-side with this document; the visual continuity should be obvious.

A reminder of the baseline's primitives (full table in `requirements.md` §"Visual baseline"):

```
                                                                   ← .menubar (26pt, glass blur, REC pill on right)
┌──────────────────────────────────────────┐                       ← .popover  (14pt radius, glass material)
│  recording-2026-04-30-20-25       ●…  Idle│ ← .header
│  ▴                                        │ ← popover arrow ::before
├──────────────────────────────────────────┤
│  GENERAL                                  │ ← .section-title
│  ┌────────────────────────────────────┐  │ ← .group
│  │ Format            [ m4a — AAC  ⌄ ] │  │ ← .row + .popup
│  │ Layout            [ Mixed       ⌄ ] │  │
│  │ Save to           📁 Recordings    │  │ ← .row + .path
│  │ Microphone        [ Default     ⌄ ] │  │
│  └────────────────────────────────────┘  │
│                                          │
│  LIVE TRANSCRIPTION         Soniox  ● ═○ │ ← .section-title.with-toggle + .switch.on
│  ┌────────────────────────────────────┐  │
│  │ Engine            [ Soniox      ⌄ ] │  │
│  │ Source            [ Mixed       ⌄ ] │  │
│  │ Sidecar format    [ JSONL       ⌄ ] │  │
│  │ Language          [ el-GR       ⌄ ] │  │
│  │ ─────────────────────────────────  │  │ ← .row-sub
│  │ SONIOX API KEY · ● Configured     │  │
│  │ [ •••••••••• ] [ Replace… ]       │  │ ← .key-input + .btn
│  └────────────────────────────────────┘  │
│                                          │
│  ● Ready                     [● Start ]  │ ← .footer + ready-pill + .record-btn (red gradient)
└──────────────────────────────────────────┘
```

All new surfaces in this proposal **re-use that grammar verbatim** — same row height, same hairlines, same section-title typography, same switch graphic, same path control, same record-button geometry (only the gradient hue changes for non-Record primary actions).

The canonical states map 1:1 to the UX states described in `requirements.md`:

| # | State | Trigger | Persists when… |
|---|---|---|---|
| 0 | Not recording (feature dormant) | Session in `.idle / .stopped / .failed` | — |
| 1 | Idle / docked pill | Recording in progress, overlay not summoned | Always, while recording |
| 2 | Question typed | `⌥⇧Space` (FR-IRQ-1) / click pill (FR-IRQ-2) | Until Submit / Esc / focus-loss |
| 3 | Answering (streaming) | Return pressed after typing | Until last-token / cancel |
| 4 | Answer shown + history + timeline | First answer completed | Until Stop (clears) or Pin pushed |
| 5 | Error states | Credential missing / stream error / empty context | Until acknowledged |
| 6 | **Save Transcript dialog** | Click `Save Transcript…` after Stop (FR-IRQ-24) | Until Save / Cancel |
| 7 | **Saved confirmation toast** | After successful file write (FR-IRQ-30) | 4 s auto-dismiss / click |

---

## State 0 — Not recording (feature dormant)

```
                            ┌──────────────────────────────────────────┐
                            │  recording-…  Idle  · ~/Recordings · Idle│  ← baseline popover, unchanged
                            ├──────────────────────────────────────────┤
                            │  GENERAL                                  │
                            │  …                                        │
                            │                                          │
                            │  ● Ready                     [● Start ]  │  ← baseline footer, unchanged
                            └──────────────────────────────────────────┘

                            (no Ask pill on screen,
                             ⌥⇧Space is UNREGISTERED)
```

**Caption.** The popover is exactly the baseline mockup — the Ask feature deliberately leaves no trace when there's nothing to ask about, keeping the menu-bar attack surface small. The Start button is the red `.record-btn` from the baseline.

---

## State 1 — Idle / docked pill

```
   ┌──────────────────────────────────────────────────────────────┐
   │            ░ user's frontmost app window ░                   │
   │            ░ (Zoom, Teams, browser, etc.)  ░                │
   │            ░                                ░                │
   └──────────────────────────────────────────────────────────────┘
                                                ┌─────────────────────┐
                                                │ ●  Ask… ⌥⇧Space  ⊕ │  ← reuses .perm-pill shape
                                                └─────────────────────┘     (rounded 100pt, 11pt label,
                                                                            glass blur, success-dot left)
```

**Caption.** A 28-pt-tall pill docked to the bottom-right of the active display. **Geometry borrowed verbatim from `.perm-pill`** in the baseline (`docs/design/mockups/popover-redesign.html` line ~234) — same 100pt radius, same internal padding (2pt 8pt 2pt 6pt), same 10.5pt CAPS-like label. The leading `●` re-uses the `.menubar .recording-anchor .dot` red gradient so the pill reads as a live-recording indicator. The trailing `⊕` glyph is the "expand to overlay" target for trackpad users. Hover tooltip: *"Ask a question about this recording — your audio keeps recording uninterrupted"*. The pill docks to the *display* edge so it never overlaps a meeting-window control bar.

---

## State 2 — Question typed (about to submit)

```
┌────────────────────────────────────────────────────────────────────┐  ← .popover frame (light variant
│  Ask the recording                                  ●  03:14   📌 │     400pt wide; 14pt radius;
│                                                                    │     same glass material as baseline)
├────────────────────────────────────────────────────────────────────┤
│  CONTEXT                                                           │  ← .section-title
│  ┌──────────────────────────────────────────────────────────────┐  │  ← .group
│  │ Window           [ Last 5 min                            ⌄ ] │  │  ← .row + .popup
│  │ Provider         [ openai (gpt-4o)                       ⌄ ] │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │  ← .group wrapping input
│  │ 🎙 What was the customer's title again?▌                     │  │  ← .key-input (widened)
│  └──────────────────────────────────────────────────────────────┘  │     mic icon = greyed v2 stub
│                                                                    │
│  Esc dismiss                                            [ ↩ Send ]│  ← .footer; Send is a blue
└────────────────────────────────────────────────────────────────────┘     variant of .record-btn
```

**Caption.** The overlay's compact form when freshly summoned. The header is built from the **exact `.header` primitive** of the baseline: filename slot replaced by the static title "Ask the recording"; the meta row carries the live REC dot (`.menubar .recording-anchor .dot`), the elapsed clock (`mm:ss`), and the unpinned-pin glyph. The pin (`📌`) sits in the same horizontal position the baseline's "Idle" state pip occupies.

The context strip is **a real `.group` of two `.row`s** — Window and Provider use `.popup` selects identical to those in the baseline's General / Live Transcription sections. The input itself is a wide `.key-input` (mono-monospace replaced by sans for readability, but identical chrome). The Send button is a *blue* variant of the baseline's `.record-btn` — same shape, same shadow, same gradient mechanic, just `--accent` rather than `--record-grad` (this convention is used everywhere a primary "go" action that is not Record appears).

The greyed-out mic icon reserves the v2 voice-input affordance (FR-IRQ-5). Clicking outside (when pin is off) animates the window to the State 1 pill — the dock animation is the same scale-down used by the popover when it loses focus on master.

---

## State 3 — Answering (streaming)

```
┌────────────────────────────────────────────────────────────────────┐
│  Ask the recording                                  ●  03:17   📌 │
├────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────────┐  │  ← .group
│  │ You · 03:14                                                  │  │  ← .row .label
│  │   What was the customer's title again?                       │  │  ← .row .control
│  ├──────────────────────────────────────────────────────────────┤  │  ← .separator hairline
│  │ Assistant · 03:15    ◐ streaming…                            │  │  ← .row (live indicator
│  │   Sarah Chen introduced herself at 02:41 as "VP of           │  │     uses accent + pulse)
│  │   Platform Engineering" at Northwind. She also               │  │
│  │   mentioned she reports to ▌                                 │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ▎mic ▰▰▰▱▱▱▱     ▎sys ▰▰▰▰▰▱▱       ⌘C  Esc cancel              │  ← .footer; level meters re-use
└────────────────────────────────────────────────────────────────────┘     LevelMeterView styling
```

**Caption.** While the LLM is streaming, three things happen simultaneously, and the layout makes all three visible:

1. The question is now displayed verbatim in the top `.row` of the `.group`, with a `mm:ss` recording-relative timestamp.
2. The assistant's response renders inside a paired `.row` separated by the standard 0.5 px `var(--separator)` hairline — identical to the row separators on the baseline's General section. The `▌` caret at the end is the live cursor.
3. The bottom footer shows the **mic and system-audio level meters still ticking** — live proof of FR-IRQ-22 that the audio path is uninterrupted.

The `◐` pulse glyph (production: `circle.dotted.circle` SF Symbol with a 1.5 s pulse) is **intentionally not a spinner**. The requirement (FR-IRQ-8) is to distinguish *active token streaming* from *idle waiting for the server*. Pulse fades in/out in time with token arrivals.

`Esc cancel` aborts the in-flight LLM request via the `Task` cooperative-cancellation boundary in FR-IRQ-21; partial answer text remains visible with a `(cancelled)` tag in the `--secondary` color.

---

## State 4 — Answer shown + history + timeline

```
┌────────────────────────────────────────────────────────────────────┐
│  Ask the recording                                  ●  06:42   📌 │
│  ┃━━━┃━━┃━━━━━━━━━━┃━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┃━━━━━━━━━━━━│  ← timeline strip
│   Q1 A1 Q2 A2                                       Q3 (here)     │     tick = --accent
├────────────────────────────────────────────────────────────────────┤    span = --accent @ 35% alpha
│  ┌──────────────────────────────────────────────────────────────┐  │   line = --separator
│  │ You · 03:14                                                  │  │
│  │   What was the customer's title again?                       │  │
│  ├──────────────────────────────────────────────────────────────┤  │
│  │ Assistant · 03:15                            [ ▾ 7 lines ]   │  │
│  │   Sarah Chen introduced herself at 02:41 as "VP of           │  │
│  │   Platform Engineering" at Northwind. …                      │  │
│  ├──────────────────────────────────────────────────────────────┤  │
│  │ You · 05:02                                                  │  │
│  │   Summarise the last 5 minutes.                              │  │
│  ├──────────────────────────────────────────────────────────────┤  │
│  │ Assistant · 05:03                            [ ▴ collapse ]  │  │
│  │   The team agreed to a 6-week pilot starting June 2.         │  │
│  │   Sarah pushed back on SSO timing; you offered a workaround  │  │
│  │   via SAML federation. Open questions: pricing tier for      │  │
│  │   burst usage, who from legal signs the DPA. …               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │  ← persistent input .group
│  │ 🎙 ▌                                                         │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  context: last 5 min · openai (gpt-4o)                  [ ↩ Send ]│
└────────────────────────────────────────────────────────────────────┘
```

**Caption.** The full overlay after at least one Q&A round-trip. Compared to State 3, three new affordances are visible:

- **Timeline strip in the header.** Three glyph classes per FR-IRQ-12 — `┃` ticks for *question-time* in `--accent`; `━` runs immediately following a tick for *answer-time spans* in `--accent` at 35 % alpha; the continuous `━` background for *continued recording* in `--separator` color. Clicking a tick jumps the history pane to that exchange (FR-IRQ-13). "You are here" pins the current recording head (the `●` red dot) at the right edge.
- **Per-exchange collapse/expand controls.** `[ ▾ 7 lines ]` collapses long answers to a one-line preview by default; `[ ▴ collapse ]` reverses it. The toggle chrome reuses the `.btn` styling from the baseline. The toggle is purely client-side — no re-query (FR-IRQ-9).
- **Empty input bar at the bottom.** A second `.group` containing one `.key-input`-styled row. The user can immediately type their next question; previous exchanges scroll upward. Keyboard focus stays on this input.

The right-edge gutter (omitted from ASCII) carries a tiny `⋯` per exchange that opens a per-message `.btn` popover menu: *Copy answer*, *Copy question + answer*, *Regenerate*, *Hide from sidecar*.

---

## State 5 — Error states

There are three failure modes the user can hit. Each renders inside the overlay (no system modal — modals would steal focus from the user's conversation window). All three reuse the **`.row-sub`** primitive from the baseline (the same shape used to host the API-key sub-row in the Live Transcription section), recolored to a warning palette via `--warn` (a new token mirroring `--success-*` and added to both light & dark variant blocks).

### 5a — No credential resolved (FR-IRQ-19)

```
┌────────────────────────────────────────────────────────────────────┐
│  Ask the recording                                  ●  03:14   📌 │
├────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────────┐  │  ← .group
│  │ ⚠ OPENAI API KEY · Not configured                            │  │  ← .row-sub
│  │ macrec checks OPENAI_API_KEY in your shell, then              │  │     (warn palette)
│  │ ~/.tool-agents/macrec/.env, then ./.env.                     │  │
│  │ [ Open Settings ▸ Live Transcription ▸ OpenAI key… ]         │  │  ← .btn deep link
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**Caption.** Typed error, no silent fallback. The deep-link `.btn` opens the same Settings sheet the popover uses for per-provider API-key entry.

### 5b — Stream errored mid-answer

```
│  ┌──────────────────────────────────────────────────────────────┐
│  │ Assistant · 03:15      ⚠ stream interrupted (HTTP 429)       │
│  │   Sarah Chen introduced herself at 02:41 as "VP of           │
│  │   Platform Engineering" at North…           [ Retry ]        │   ← .btn inline
│  └──────────────────────────────────────────────────────────────┘
```

**Caption.** Partial answer is preserved and persisted. The `[ Retry ]` `.btn` re-issues the same question with the same context window (no new audio is added between attempts — keeps the audit trail of the persisted sidecar clean).

### 5c — Empty transcript context

```
│  ┌──────────────────────────────────────────────────────────────┐
│  │ ⚠ NO TRANSCRIPT YET                                          │
│  │ Live transcription is off, or just started. I can still      │
│  │ answer from general knowledge but can't reference the        │
│  │ conversation.                                                │
│  │                                  [ Continue anyway ] [ Cancel ]│
│  └──────────────────────────────────────────────────────────────┘
```

**Caption.** Surfaces the degraded-mode posture explicitly so the user is never confused about why the answer is generic.

---

## State 6 — Save Transcript dialog (NEW — FR-IRQ-23..32)

The Save Transcript dialog opens when the user clicks **`Save Transcript…`** in the popover footer **after** the recording has stopped (FR-IRQ-23). It is the canonical end-of-session export surface. Visually it is a wider variant (480 pt) of the same `.popover` frame chrome, anchored to the menu-bar item so it reads as an extension of the popover itself.

### 6a — Popover footer transition (Recording → Stopped → Save)

The popover's footer changes state in three steps. The third step is the new "Save Transcript…" affordance.

```
RECORDING  →  ● 14:30 · 24 segments              [ ■ Stop ]      ← .record-btn red (existing)

STOPPED    →  ✓ Recorded 14:30   · 47 min 22 s  [ Save Transcript… ]   ← blue gradient variant
                                                  [ Reveal in Finder ]  ← .btn secondary
                                                  [ New Recording   ]   ← .btn secondary
```

The blue-gradient `Save Transcript…` button uses the **same geometry as `.record-btn`** (border-radius 8 pt, padding 7 pt 16 pt 7 pt 12 pt, font 13.5 pt 600, identical shadow stack) — only the gradient swaps from `--record-grad` to a blue gradient computed from `--accent`.

### 6b — Save Transcript dialog, default state

```
┌────────────────────────────────────────────────────────────────────────┐  ← .popover (480pt, light)
│  recording-2026-05-12-14-30.md             ✓ Ready to save · ~1.2 MB  │  ← .header + .perm-pill
│                                                                        │     (filename = .header-input,
│  📁  Recordings              Choose…                                    │      editable inline)
├────────────────────────────────────────────────────────────────────────┤
│  EXPORT OPTIONS                                                        │  ← .section-title
│  ┌──────────────────────────────────────────────────────────────────┐  │  ← .group
│  │ Format             [ Markdown — .md (recommended)            ⌄ ] │  │  ← .row + .popup
│  ├──────────────────────────────────────────────────────────────────┤  │
│  │ Include Q&A interjections                                ●═○     │  │  ← .row + .switch.on
│  ├──────────────────────────────────────────────────────────────────┤  │
│  │ Include timestamps                                        ●═○    │  │
│  ├──────────────────────────────────────────────────────────────────┤  │
│  │ Include audio file reference                              ●═○    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  WHAT'S INCLUDED                       54 segments  ·  3 Q&A pairs    │  ← .section-title
│  ┌──────────────────────────────────────────────────────────────────┐  │  ← .group + .key-input mono
│  │ # recording-2026-05-12-14-30                                      │  │     (read-only preview)
│  │ _Audio: recording-2026-05-12-14-30.m4a · 47 min 22 s_             │  │
│  │                                                                   │  │
│  │ **Mic · 00:00:04** — Hi Sarah, thanks for taking the time today. │  │
│  │ **System · 00:00:08** — Of course! Happy to walk through the     │  │
│  │                          security review.                         │  │
│  │ …                                                                 │  │
│  │ > 🅀 03:14 — What was the customer's title again?                 │  │
│  │ > 🅐 03:15 — Sarah Chen introduced herself at 02:41 as "VP of    │  │
│  │              Platform Engineering" at Northwind.                  │  │
│  │ …                                                                 │  │
│  │ **Mic · 05:14** — Right, so on the SSO question…                  │  │
│  │ …                                                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  [ Cancel ]       [ Reveal in Finder ]              [ Save  ↩ ]      │  ← .footer; Cancel + Reveal are
└────────────────────────────────────────────────────────────────────────┘     .btn secondary; Save is the
                                                                              blue .record-btn variant
```

**Caption.** The dialog reuses **every** primitive from the baseline:

- **Header** (`.header` + `.header-input`) — editable filename in the same 17 pt 600 typography as the popover's filename row, with the same hover/focus chrome (`.header-input:hover` reveals `--chip-bg` background; `:focus` reveals the 3 pt accent ring). The status pill on the right is a `.perm-pill` recolored to the size estimate.
- **Path control** (`.path` + `.folder-ico` + `.change`) — identical to the "Save to" row in the baseline; clicking "Choose…" opens an `NSOpenPanel`.
- **Sections** (`.section-title` CAPS + `.group`) — same 11 pt 600 0.07 em tracking, same 10 pt rounded group, same 0.5 px hairline rows.
- **Format select** (`.popup`) — the same NSPopUpButton-styled select used by the General section's Format / Layout / Microphone rows. The "(recommended)" suffix matches FR-IRQ-25.
- **Toggles** (`.switch`) — three identical toggles in the same On (green track + white knob right) / Off (grey track + white knob left) styling as the baseline's "Soniox" engine switch.
- **Preview** (`.key-input` mono) — the same monospaced field used by the API-key sub-row, expanded to a multi-line read-only `<pre>`-style container. Reactive — re-renders ≤ 50 ms on any change per NFR-IRQ-Save-Latency.
- **Footer** — Cancel and Reveal in Finder are `.btn` secondaries; Save is the blue variant of `.record-btn` (FR-IRQ-23). Tab order: filename → Choose → Format → toggles (top to bottom) → preview-focus (passive) → Cancel → Reveal → Save.

### 6c — Save Transcript dialog with toggles flipped (alternative preview)

To make FR-IRQ-26's reactivity concrete: with **Include Q&A interjections = Off** and **Include timestamps = Off**, the preview pane collapses to a clean reader-mode transcript.

```
│  ┌──────────────────────────────────────────────────────────────────┐
│  │ # recording-2026-05-12-14-30                                      │
│  │                                                                   │
│  │ **Mic** — Hi Sarah, thanks for taking the time today.            │
│  │ **System** — Of course! Happy to walk through the security        │
│  │              review.                                              │
│  │ **Mic** — Right, so on the SSO question, we'd love to            │
│  │           understand…                                             │
│  │ …                                                                 │
│  └──────────────────────────────────────────────────────────────────┘
```

The size estimate in the header pill drops accordingly (`~620 KB` instead of `~1.2 MB`).

### 6d — Save Transcript dialog — overwrite warning (FR-IRQ-32)

If a file with the chosen name already exists, the dialog inserts a non-modal `.row-sub` warning **inside the dialog body** (above the footer), in the warn palette, with three action `.btn`s. No silent overwrite. No silent rename. No modal.

```
│  ┌──────────────────────────────────────────────────────────────────┐
│  │ ⚠ FILE EXISTS                                                    │
│  │ recording-2026-05-12-14-30.md already exists in ~/Recordings.    │
│  │ [ Replace ]   [ Append timestamp ]   [ Cancel ]                  │
│  └──────────────────────────────────────────────────────────────────┘
```

"Append timestamp" rewrites the filename in the header field to `recording-2026-05-12-14-30-2.md` (next free integer) and clears the warning.

### 6e — Save Transcript dialog — format = JSON variant

When the user picks **JSON**, the preview pane re-renders as syntax-highlighted JSON. Toggle row "Include audio file reference" governs whether the top-level `audio_path` key is emitted.

```
│  ┌──────────────────────────────────────────────────────────────────┐
│  │ {                                                                 │
│  │   "recording": "recording-2026-05-12-14-30",                      │
│  │   "audio_path": "./recording-2026-05-12-14-30.m4a",               │
│  │   "duration_ms": 2842000,                                         │
│  │   "segments": [                                                   │
│  │     { "type":"speech","ts_ms":4000,"speaker":"mic",               │
│  │       "text":"Hi Sarah, thanks for taking the time today." },     │
│  │     { "type":"speech","ts_ms":8000,"speaker":"system",            │
│  │       "text":"Of course! Happy to walk through…" },               │
│  │     { "type":"qa","ts_ms":194000,                                 │
│  │       "question":"What was the customer's title again?",          │
│  │       "answer":"Sarah Chen introduced herself at 02:41 as…",      │
│  │       "model":"gpt-4o","provider":"openai" }                      │
│  │   ]                                                               │
│  │ }                                                                 │
│  └──────────────────────────────────────────────────────────────────┘
```

### 6f — Save Transcript dialog — format = SRT variant

SRT cannot carry Q&A interjections per FR-IRQ-25 (subtitles are mono-stream). The dialog disables the **Include Q&A interjections** toggle when format = SRT and surfaces a `.row-sub` info note explaining that a sibling `.questions.srt` is written for the Q&A track.

```
│  ┌──────────────────────────────────────────────────────────────────┐
│  │ Format             [ SRT — .srt                              ⌄ ] │
│  ├──────────────────────────────────────────────────────────────────┤
│  │ Include Q&A interjections                          ○═●   (n/a)  │  ← .switch disabled
│  ├──────────────────────────────────────────────────────────────────┤
│  │ Include timestamps                                      ●═○      │
│  ├──────────────────────────────────────────────────────────────────┤
│  │ Include audio file reference                            ●═○      │
│  └──────────────────────────────────────────────────────────────────┘
│  ⓘ SRT can't carry Q&A interjections — they'll be written to a       │  ← .row-sub info
│     sibling file: recording-2026-05-12-14-30.questions.srt           │
```

---

## State 7 — Saved confirmation toast (FR-IRQ-30)

After a successful file write, a single `.status-chip` (success palette: `--success-bg`, `--success-fg`, `--success-dot`) appears under the menu-bar item — anchored at the same x-coordinate as the popover would be, but rendered as a free-standing toast NSWindow with no arrow.

```
                                    ┌──────────────────────────────────────────────────┐
                                    │ ● ✓ Saved to ~/Documents/recording-2026-05-12-…  │ ← .status-chip
                                    └──────────────────────────────────────────────────┘     (success palette,
                                                                                              4s auto-dismiss,
                                                                                              click → Finder)
```

**Caption.** The toast reuses **the same** `.status-chip` geometry that appears in the baseline's API-key sub-row ("Configured · expires 2026-09-01") — same dot, same color, same padding, same font size. It floats free of the popover and auto-dismisses after 4 s. Clicking it opens the file in Finder. Toast dismissal MUST NOT block subsequent actions.

If the write **fails** (disk full, permission denied), the toast renders in the warn palette with `⚠` instead of `✓`, and persists until clicked.

---

## Layout notes for the implementing engineer

- **Window class.** Frameless `NSWindow`, `level = .floating`, `collectionBehavior` includes `.canJoinAllSpaces` + `.fullScreenAuxiliary` so it travels with the user across Spaces and shows over a fullscreen Zoom call. Same class for both the Ask overlay and the Save Transcript dialog (the dialog additionally adopts `.titled` for the close button but still has no title bar visible — chrome is drawn manually as in the popover).
- **Anchor & resize.** Ask overlay: default position top-right of the active screen, 24 pt inset; stored in `@AppStorage("com.macrec.ui.askOverlayFrame")`; width 400 pt, height grows from 160 pt minimum to 640 pt maximum, then becomes scrollable. Save Transcript dialog: anchored to menu-bar item; width 480 pt; height auto-fits content up to a 720 pt cap.
- **Activation policy.** The Ask overlay should NOT steal application focus when summoned (so Zoom keeps capturing the user's keyboard for mute/unmute). Use `NSWindow.becomesKeyOnlyIfNeeded = true` and a custom first-responder chain that only takes the keyboard when the input field is focused. The Save Transcript dialog DOES take key on open — the user's intent is to fill it out.
- **Dismissal.** Ask overlay: Esc → animate to State 1 pill; click-outside without Pin → animate to State 1 pill; Pin → stays put on click-outside. Save Transcript dialog: Esc → cancel; ⌘W → cancel; ⌘S → submit.
- **Accessibility.** Every interactive element gets a `.accessibilityLabel` and a localized `.help` tooltip; both surfaces register with VoiceOver. Ask-overlay tab order: input → Send → Pin → Close → history (newest first). Save-dialog tab order per § 6b above.
- **Theming.** Re-use **the exact CSS variables / SwiftUI semantic colors** named in `requirements.md` §"Visual baseline" — `--label`, `--value`, `--secondary`, `--separator`, `--group-bg`, `--accent`, `--success-bg/fg/dot`, plus a new `--warn-*` triad mirroring `--success-*` for the warning row variants in State 5 and State 6d. Light / dark / system auto-switch must work the same way the baseline popover already does (CSS variable swap; SwiftUI `Environment(\.colorScheme)`).
- **Reusable view modules.** The Save Transcript dialog's preview pane and the Q&A history pane share enough chrome (mono font, group + hairlines, scrollable container) that a single `TranscriptRenderView` SwiftUI view should serve both — parametrized by `RenderMode = .liveHistory | .savePreview`.
