# ntakker — Phase K Manual Smoke-Test Checklist

> Phase K acceptance verification for `ntakker` (plan-002 §3 Phase K).
> Each item maps 1:1 to an acceptance criterion (AC-UI-1..AC-UI-18) from
> `docs/design/refined-request-toolbar-ui.md`.
> Run on a real macOS 14+ host while logged in as the user.
>
> Conventions:
> - `[ ]` = not-yet-verified item; tick to `[x]` once observed.
> - "Reset TCC" steps reference `tccutil`; you will need to re-grant
>   afterwards.
> - Build the artefact under verification with `swift build -c release`
>   first; the binary is at `.build/release/ntakker`.
> - The CLI binary at `.build/release/ntakker-cli` is referenced for AC-UI-11
>   (mic-list parity) and AC-UI-14 (CLI regression).

## 0 — Pre-flight

- [ ] `swift build -c release` exits 0 with no warnings (CI gate).
- [ ] `.build/release/ntakker-cli` and `.build/release/ntakker` are both
      executable.
- [ ] `otool -s __TEXT __info_plist .build/release/ntakker` prints a
      non-empty `__info_plist` section (TCC binding pre-requisite).
- [ ] Confirm bundle id in the embedded plist:
      `otool -s __TEXT __info_plist .build/release/ntakker | xxd -r -p | grep -a com.local.ntakker`.
- [ ] No stale UI is running:
      `pgrep -lf ntakker` returns empty before each scenario.

## AC-UI-1 — Build cleanliness (build-time)

- [ ] `swift build -c release 2>&1 | grep -E "(warning|deprecated)"`
      returns nothing related to the new `Sources/ntakker/`,
      `Sources/NtakkerUIKit/`, or new `Sources/NtakkerCore/SessionState.swift`
      files. (Pre-existing R-20 warnings in
      `M4ARecorder.swift` / `SCKitSystemAudioSource.swift` only show up
      under `-strict-concurrency=complete`; ignore those.)

## AC-UI-2 — First-launch permission state + Start gating

- [ ] Reset both grants:
      `tccutil reset ScreenCapture com.local.ntakker`
      `tccutil reset Microphone com.local.ntakker`.
- [ ] Launch `.build/release/ntakker`. The status item appears in the
      menu bar; click it.
- [ ] Popover opens. The two `PermissionStatusView` rows show
      "Screen Recording: not determined" and "Microphone: not determined".
- [ ] The Start button is either visibly disabled, or — if the current
      build relies on the engine to throw — clicking Start surfaces the
      `failed(.permissionDenied(...))` banner without a partial file.
      *If the latter, file a follow-up: FR-37 specifies the Start button
      MUST be `.disabled` at the SwiftUI level with a tooltip; the
      current implementation lets the engine throw instead. Low-risk
      because the engine still refuses to start, but spec-noncompliant.*

## AC-UI-3 — Permission deep-links

- [ ] With Screen Recording status `notDetermined`, click the
      "Grant…" affordance on its row → macOS TCC prompt appears.
- [ ] Decline the Screen-Recording prompt. Re-open the popover; the
      row now reads "Screen Recording: denied". Click the row →
      `Privacy & Security → Screen Recording` opens in System Settings.
- [ ] Repeat for Microphone:
      decline → state flips to `denied` → click → `Privacy & Security →
      Microphone` opens in System Settings.

## AC-UI-4 — Start latency

- [ ] Grant both permissions, relaunch the UI, open the popover.
- [ ] Press Start with a stopwatch handy. Observe:
  - [ ] Status-icon transitions to the recording (red dot) state within
        100 ms (visual judgement; or instrument with `os_signpost` and
        check Console).
  - [ ] On disk, the `.partNN` or bare-named output file appears within
        1 s under the resolved folder
        (default `~/Recordings/recording-YYYY-MM-DD-HH-mm.m4a`).
- [ ] Note actual latency for record-keeping.

## AC-UI-5 — Stop produces a playable file

- [ ] Recording from AC-UI-4 still active. Wait ≥ 5 s for content.
- [ ] Press Stop. Status-icon returns to neutral.
- [ ] Drag the produced `.m4a` into QuickTime Player → plays end-to-end.
- [ ] `afinfo <file>.m4a | grep "estimated duration"` matches the UI's
      elapsed-time read-out within ±0.5 s.

## AC-UI-6 — Pause / Resume produces consecutive `partNN` files (R-31)

- [ ] Start a fresh recording (basename `pause-test`, format `m4a`,
      layout `mixed`).
- [ ] After 5 s, Pause. Wait 3 s. Resume. After 5 s, Stop.
- [ ] In the output folder, expect (R-31 verified):
  - `pause-test.part01.m4a` — first segment, renamed from
    `pause-test.m4a` on the seg-1→seg-2 transition.
  - `pause-test.part02.m4a` — second segment.
- [ ] Both files are playable in QuickTime; concatenated duration
      ≈ 10 s of audio (gap during pause is *not* recorded — stop-and-stitch).
- [ ] Pause-segment-finalize round-trip ≤ 30 s (FR-20 watchdog
      headroom).

## AC-UI-7 — Manual split: seam ≤ 250 ms

- [ ] Start a fresh recording (basename `split-test`).
- [ ] After 5 s, click Split. After another 5 s, Stop.
- [ ] Output folder contains `split-test.part01.m4a` and
      `split-test.part02.m4a`.
- [ ] Concatenate via `cat` is NOT meaningful for m4a; instead:
      `afinfo split-test.part01.m4a | grep duration` and same for
      part02. Sum vs UI cumulative-elapsed ≤ 250 ms gap (250 ms ceiling
      from FR-32; R-25 estimates ~52 ms typical).
- [ ] Listen seam-to-seam in an editor (e.g. Audacity) — no audible
      pop or > 250 ms silence.

## AC-UI-8 — Filename field locks during recording

- [ ] Open popover. Type `custom-name` into the FilenameField.
      Verify the resolved-path preview updates.
- [ ] Press Start. Try to edit the FilenameField → it is non-editable
      (greyed/locked). Field is re-enabled after Stop.

## AC-UI-9 — Folder picker persists across launch (R-32 verified)

- [ ] Open popover. Click "Choose Folder…". Pick `/tmp/ntakker-cli-smoke/`
      (create if missing).
- [ ] Quit the UI: `pkill ntakker` (or use the Quit menu).
- [ ] Relaunch `.build/release/ntakker`. Open popover. Folder field
      shows `/tmp/ntakker-cli-smoke/`.
- [ ] Press Start. After Stop, the file lives under
      `/tmp/ntakker-cli-smoke/`.
- [ ] **R-32 default-folder**: with no prior pick, freshly-launched
      UI resolves to `~/Recordings/` and creates the directory if
      missing. Press Start; file lands in `~/Recordings/`.

## AC-UI-10 — `--layout split` + Pause = four `.partNN.{mic,system}` files (R-31)

- [ ] Open popover. Layout dropdown → `split`.
- [ ] Basename `splitlayout-test`, format `m4a`.
- [ ] Press Start. After 5 s, Pause. Wait 3 s. Resume. After 5 s, Stop.
- [ ] Output folder contains exactly four files (R-31 verified):
  - `splitlayout-test.part01.system.m4a`
  - `splitlayout-test.part01.mic.m4a`
  - `splitlayout-test.part02.system.m4a`
  - `splitlayout-test.part02.mic.m4a`
- [ ] All four files playable; mic file shows mic content only,
      system file shows system content only.

## AC-UI-11 — Mic dropdown parity + hot-plug refresh

- [ ] Open popover. Mic dropdown shows at least the system-default
      built-in microphone.
- [ ] Compare to `.build/release/ntakker-cli list-devices` output:
      every device in CLI output is also in UI dropdown (UID-keyed).
- [ ] Plug in a USB mic. Within 2 s the dropdown gains a new entry.
- [ ] Unplug. Within 2 s the entry disappears (or, if the UID was
      the active selection, the picker reverts to system default).

## AC-UI-12 — Elapsed-time indicator

- [ ] Start a recording. Observe ElapsedTimeView ticking at 1 Hz —
      no skipped seconds for at least 30 s.
- [ ] Pause → segment timer freezes; cumulative timer also freezes
      (stop-and-stitch — no audio captured during pause).
- [ ] Resume → both timers tick again.
- [ ] Stop → timers stop and the popover shows the final cumulative
      elapsed.

## AC-UI-13 — Force-quit during recording leaves a playable partial

- [ ] Start a recording. After 10 s, force-quit:
      `kill -9 $(pgrep ntakker)`.
- [ ] On disk, the in-flight `.m4a` file is present but not
      gracefully finalized. Verify it is still playable end-to-end in
      QuickTime (FR-21 fragment-based recovery).
- [ ] Note: split / pause segments produced before the force-quit are
      always finalized cleanly because the engine flushes on each
      segment boundary.

## AC-UI-14 — CLI regression gate

- [ ] Run the existing CLI smoke suite:
      `bash test_scripts/e2e-30s-mixed.sh`.
- [ ] Run `bash test_scripts/e2e-detach-stop.sh`.
- [ ] Run `bash test_scripts/e2e-stop-already-recording.sh`.
- [ ] Run `bash test_scripts/e2e-stop-stale.sh`.
- [ ] Run `bash test_scripts/e2e-sigint-finalize.sh`.
- [ ] All scripts report PASS. (Skip `e2e-60min-stability.sh` unless
      time permits.)

## AC-UI-15 — Tool-conventions audit (R-33 verified)

- [ ] `docs/tools/ntakker.md` exists and uses the `<ntakker-cliUi>` XML
      root with `<objective>`, `<command>`, `<info>` blocks.
- [ ] `~/.tool-agents/ntakker/` exists at mode `0700`
      (`stat -f '%Sp' ~/.tool-agents/ntakker/` → `drwx------`).
- [ ] `~/.tool-agents/ntakker/.env` exists at mode `0600`
      (`stat -f '%Sp' ~/.tool-agents/ntakker/.env` → `-rw-------`).
- [ ] Project `CLAUDE.md` `## Tools` section lists `ntakker` with a
      relative link to `docs/tools/ntakker.md`.
- [ ] The five `@AppStorage` keys
      (`com.ntakker-cli.ui.{outputFolder,basename,format,layout,micUID}`)
      match the UI source.
- [ ] If the `/tool-conventions audit ntakker` slash command is
      available in your harness, run it and confirm exit 0.

## AC-UI-16 — `project-functions.md` updated (R-34 verified)

- [ ] `docs/design/project-functions.md` contains FR-30..FR-44.
- [ ] Status lines for FR-30..FR-44, NFR-11..NFR-12, NFR-14..NFR-16
      read `IMPLEMENTED (Phase X completed 2026-04-26)` (or richer).
- [ ] NFR-13 (footprint envelope) is allowed to remain
      `PLANNED. Phase: K verification` until the smoke run completes.

## AC-UI-17 — `project-design.md` UI architecture section

- [ ] `docs/design/project-design.md` contains a §15 (or appropriate)
      UI section covering: status item + popover + activation policy
      (§15.4); pause/resume/split semantics; `SessionState` enum;
      segment-naming scheme (FR-34).

## AC-UI-18 — `Issues - Pending Items.md` reflects residuals

- [ ] R-22..R-30 listed in **Pending** (most-critical-first ordering).
- [ ] R-31..R-34 listed in **Completed** with their resolutions.
- [ ] ISSUE-02 listed in Completed (resolved by Phase A `PermissionGating`).
- [ ] No new risks surfaced during Phase K? Otherwise add as R-35+.

## NFR-13 — Footprint (defer-to-K verification per spec)

- [ ] Idle (popover closed, no recording): RSS < 80 MB.
      `ps -o rss= -p $(pgrep ntakker)` returns < 81920 (kB).
- [ ] During a 5-minute recording: RSS < 250 MB; CPU < 25 % of one
      core measured by `top -pid $(pgrep ntakker) -l 30`.

## Sign-off

- [ ] Date: ____________________
- [ ] Operator: ____________________
- [ ] All AC-UI-1..AC-UI-18 PASS, plus NFR-13. Phase K complete.
- [ ] Any new risks added to `Issues - Pending Items.md`? List them
      below for the orchestrator.
