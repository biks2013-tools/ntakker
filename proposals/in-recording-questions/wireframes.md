---
proposal: in-recording-questions
companion: requirements.md
---

# Wireframes — In-Recording Q&A

These sketches accompany `requirements.md`. The ASCII art shows the *layout intent* — the actual macOS render will be a frameless, vibrant-material rounded NSWindow (`NSWindowStyleMask.borderless`, `NSVisualEffectView` with `.hudWindow` material), anchored top-right by default and persisting its last position across sessions.

The four canonical states map 1:1 to the four UX states the requirements describe:

| # | State | Trigger | Persists when… |
|---|---|---|---|
| 1 | Idle / docked pill | Recording is in progress, user hasn't summoned overlay yet | Always, while recording |
| 2 | Question typed | User pressed `⌥⇧Space` (FR-IRQ-1) or clicked the pill (FR-IRQ-2) | Until Submit / Esc / focus-loss |
| 3 | Answering (streaming) | User pressed Return after typing | Until last-token-received or user cancels |
| 4 | Answer shown + history + timeline | First-answer completed; subsequent invocations stack | Until Stop (clears) or Pin pushed (persists across blur) |

Plus two ancillary states:

- **State 0 — Not recording** (the feature is dormant; the pill is hidden; the global hotkey is unregistered while the session is in `.idle / .stopped / .failed`).
- **State 5 — Error** (LLM credential missing; LLM call errored mid-stream; transcript context window is empty because transcription is off).

---

## State 0 — Not recording (feature dormant)

```
                                                  (no pill rendered)
                                                  global hotkey
                                                  ⌥⇧Space is
                                                  UNREGISTERED.
```

**Caption.** The popover behaves identically to today's master branch. The feature deliberately leaves no trace when there is no recording to ask about — this keeps the menu-bar attack surface small and avoids confusing "ask about what?" UX.

---

## State 1 — Idle / docked pill

```
   ┌─────────────────────────────────────────────────────────────┐
   │            ░ user's frontmost app window ░                  │
   │            ░ (Zoom, Teams, browser, etc.)  ░                │
   │            ░                                ░               │
   │            ░                                ░               │
   │            ░                                ░               │
   └─────────────────────────────────────────────────────────────┘
                                              ┌──────────────────┐
                                              │ ⌥⇧Space  Ask… ⊕ │
                                              └──────────────────┘
```

**Caption.** A 28-px-tall pill docked to the bottom-right of the active display. The pill renders the keyboard shortcut as a visible hint (Fireflies-style affordance — see `requirements.md` "Related work"). The `⊕` icon is the "expand to overlay" target for trackpad users who don't want to reach for the keyboard. Tooltip on hover: *"Ask a question about this recording — your audio keeps recording uninterrupted"*. The pill never overlaps a meeting-window control bar because it docks to the *display* edge, not the *frontmost-window* edge.

---

## State 2 — Question typed (about to submit)

```
┌────────────────────────────────────────────────────────────────┐
│  Ask the recording                                ●  03:14  📌 │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  > What was the customer's title again?▌                       │
│                                                                │
│  ─────────────────────────────────────────────────────────────  │
│  context: last 5 min  ·  provider: openai (gpt-4o)  ·  ⏎ Send  │
└────────────────────────────────────────────────────────────────┘
```

**Caption.** The overlay's compact form when freshly summoned. Header shows the **live recording indicator** (`●` ticking red dot) and the **elapsed clock** — both are reads from the existing `RecordingController.state` + `ElapsedTimeView` model on `master` (`Sources/macrec-ui/Views/ElapsedTimeView.swift`); this is proof to the user that summoning the overlay did NOT stop recording. The pin (`📌`) is in its unpinned state; if the user clicks away the overlay collapses back to State 1's pill. The context/provider strip is intentionally read-only here — to change them, the user opens Settings (gear icon would appear in the header in a fuller render). The greyed-out mic icon at the left of the input (omitted from the ASCII for clarity) reserves the v2 voice-input affordance (FR-IRQ-5).

---

## State 3 — Answering (streaming)

```
┌────────────────────────────────────────────────────────────────┐
│  Ask the recording                                ●  03:17  📌 │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  You · 03:14                                                   │
│    What was the customer's title again?                        │
│                                                                │
│  Assistant · 03:15  ◐ streaming…                               │
│    Sarah Chen introduced herself at 02:41 as "VP of            │
│    Platform Engineering" at Northwind. She also mentioned      │
│    she reports to ▌                                            │
│                                                                │
│  ─────────────────────────────────────────────────────────────  │
│  ▎mic ▰▰▰▱▱▱▱   ▎sys ▰▰▰▰▰▱▱     ⌘C copy   Esc cancel           │
└────────────────────────────────────────────────────────────────┘
```

**Caption.** While the LLM is streaming, three things happen simultaneously and are all visible:

1. The question is now displayed verbatim, with a `mm:ss` timestamp showing when it was asked relative to recording start.
2. The assistant's response is being typed in front of the user's eyes — the `▌` caret at the end is the live cursor.
3. The bottom strip shows the **mic and system-audio level meters still ticking** — the live proof of FR-IRQ-22 that the audio path is uninterrupted. Mirrors the existing `LevelMeterView` (`Sources/macrec-ui/Views/LevelMeterView.swift`).

The `◐` pulse glyph (rendered as an SF Symbol `circle.dotted.circle` with a pulse animation in production) is **intentionally not a spinner**. The requirement (FR-IRQ-8) is to distinguish *active token streaming* from *idle waiting for the server*. The pulse fades in/out in time with token arrivals.

`Esc cancel` aborts the in-flight LLM request via the `Task` cooperative-cancellation boundary referenced in FR-IRQ-21; partial answer text remains visible with a `(cancelled)` tag.

---

## State 4 — Answer shown + history + timeline

```
┌────────────────────────────────────────────────────────────────┐
│  Ask the recording                                ●  06:42  📌 │
│  ┃━━━┃━━┃━━━━━━━┃━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┃━━━━━━━━━━  │
│  Q1  A1 Q2  A2                                   Q3 (you are   │
│                                                       here)    │
├────────────────────────────────────────────────────────────────┤
│  You · 03:14                                                   │
│    What was the customer's title again?                        │
│  Assistant · 03:15      [▾ expand · 7 lines]                   │
│    Sarah Chen introduced herself at 02:41 as "VP of Platform   │
│    Engineering" at Northwind. …                                │
│                                                                │
│  You · 05:02                                                   │
│    Summarise the last 5 minutes.                               │
│  Assistant · 05:03      [▴ collapse]                           │
│    The team agreed to a 6-week pilot starting June 2.          │
│    Sarah pushed back on SSO timing; you offered a workaround   │
│    via SAML federation. Open questions: pricing tier for       │
│    burst usage, who from legal signs the DPA. Budget cap       │
│    confirmed at $48k for the pilot. Sarah's blocker: a Q3      │
│    OKR review forces a decision by June 14.                    │
│                                                                │
│  ─────────────────────────────────────────────────────────────  │
│  > ▌                                                           │
│  context: last 5 min  ·  provider: openai (gpt-4o)  ·  ⏎ Send  │
└────────────────────────────────────────────────────────────────┘
```

**Caption.** The full overlay after at least one Q&A round-trip. Three new affordances are visible compared to State 3:

- **Timeline strip in the header.** Vertical `┃` bars are *question ticks* (FR-IRQ-10/12), the `━` runs immediately following a tick are *answer spans*, and the continuous `━` background is *continued recording time*. Clicking a tick jumps the history pane to that exchange (FR-IRQ-13). "You are here" pins the current recording head (the `●` red-dot) at the right edge.
- **Per-exchange collapse/expand controls.** `[▾ expand · 7 lines]` collapses long answers to a one-line preview by default; `[▴ collapse]` reverses it. The toggle is purely client-side — no re-query (FR-IRQ-9).
- **Empty input bar at the bottom.** The user can immediately type their next question; previous exchanges scroll upward. Input keeps keyboard focus.

The right-edge gutter (not visible in ASCII) carries a tiny `⋯` per exchange that opens a per-message menu: *Copy answer*, *Copy question + answer*, *Regenerate*, *Hide from sidecar*.

---

## State 5 — Error states

There are three failure modes the user can hit, each with a distinct in-overlay treatment (NOT a system modal — modals would steal focus from the user's conversation window).

### 5a — No credential resolved (FR-IRQ-19)

```
┌────────────────────────────────────────────────────────────────┐
│  Ask the recording                                ●  03:14  📌 │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ⚠ openai is selected but no API key was found.                │
│     macrec checks OPENAI_API_KEY in your shell, then            │
│     ~/.tool-agents/macrec/.env, then ./.env.                    │
│     → Open Settings ▸ Live Transcription ▸ OpenAI key…          │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

**Caption.** Typed error, no silent fallback. Deep-link to the existing Settings sheet that already handles per-provider API-key entry.

### 5b — Stream errored mid-answer

```
│  Assistant · 03:15  ⚠ stream interrupted (HTTP 429)             │
│    Sarah Chen introduced herself at 02:41 as "VP of             │
│    Platform Engineering" at North…   [retry]                    │
```

**Caption.** Partial answer is preserved and persisted. A `[retry]` chip re-issues the same question with the same context window (no new audio is added between attempts — keeps the audit trail of the persisted sidecar clean).

### 5c — Empty transcript context

```
│  ⚠ No transcript yet (live transcription is off or just         │
│     started). I can still answer from general knowledge but     │
│     can't reference the conversation. Continue anyway?  [Yes]    │
```

**Caption.** Surfaces the degraded-mode posture explicitly so the user is never confused about why the answer is generic.

---

## Layout notes for the implementing engineer

- **Window class.** Frameless `NSWindow`, `level = .floating`, `collectionBehavior` includes `.canJoinAllSpaces` + `.fullScreenAuxiliary` so it travels with the user across Spaces and shows over a fullscreen Zoom call.
- **Anchor & resize.** Default position: top-right of the active screen, 24 pt inset. Stored in `@AppStorage("com.macrec.ui.askOverlayFrame")`. Width 480 pt, height grows from a 160 pt minimum to a 640 pt maximum as history fills, then becomes scrollable. A `ResizeHandle` (mirror of `Sources/macrec-ui/Views/ResizeHandle.swift`) gives the user manual control.
- **Activation policy.** The overlay should NOT steal application focus when summoned (so the user's Zoom window keeps capturing keystrokes for them to mute/unmute via Zoom's own shortcuts). Use `NSWindow.becomesKeyOnlyIfNeeded = true` and a custom first-responder chain that only takes the keyboard when the input field is focused — which happens *only* on `⌥⇧Space` or click.
- **Dismissal.** Esc → animate to State 1 pill. Click-outside without Pin → animate to State 1 pill. Pin pressed → window stays put on click-outside but still respects ⌘W / Esc.
- **Accessibility.** Every interactive element gets a `.accessibilityLabel` and a localized `.help` tooltip; the overlay registers with VoiceOver so VO users can navigate Q&A history with VO-arrow keys. Tab order: input → Send → Pin → Close → history (most-recent first).
- **Theming.** Re-use `Palette.swift` and `SemanticColors.swift` from `Sources/macrec-ui/Theme/`. The overlay must respect the user's appearance switch (light / dark / system) just like the popover.
