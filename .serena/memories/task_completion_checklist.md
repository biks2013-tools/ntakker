# Task Completion Checklist — recording-tool

When you finish a coding change, before declaring "done":

## Build & test
1. `swift build` — must succeed without errors. Warnings tolerated only when the file is outside the change's scope.
2. `swift test` — run the relevant suites at minimum (`MacrecCoreTests`, `MacrecUITests`). For STT / capture changes, run the smoke-lock tests if present (e.g. two-instance contract for source-split, plan-012 Phase C).
3. If you touched `macrec-ui`, also rebuild the bundled app: `bash scripts/package-macrec-ui-app.sh` (or with `SWIFT_CONFIG=debug` for faster turnaround). Apple Cloud STT, Microphone TCC, Screen Recording TCC only behave correctly inside the `.app` bundle, not via raw `swift run`.
4. For TS tool changes (`tools/*`): `npm run build` from inside the tool dir; `npm link` if testing the binary on PATH.

## Lint / format
- No project-wide lint or format command is configured. Skip unless the user adds one.

## Documentation
- If behavior changed: update `docs/design/project-design.md` and `docs/design/project-functions.md`.
- If a new plan was followed: ensure the `docs/design/plan-NNN-*.md` is current.
- If a tool's behavior, flags, or env vars changed: update `docs/tools/<tool-name>.md` AND the concise reference entry in `CLAUDE.md` "Tools".
- New env vars / config knobs → also update `docs/design/configuration-guide.md`.

## Issue log
- Open `Issues - Pending Items.md`. If your change closes any pending item, move it to the "completed" section. If you discovered a new issue, add it to the pending section in priority order.

## Permissions / TCC
- Any change touching capture, microphone, or speech APIs: verify the corresponding usage description string is present in `Resources/Info.plist` (CLI) and/or `Resources/MacrecUI-Info.plist` (UI). Embedding is via the `-Xlinker -sectcreate` flags in `Package.swift`.

## Version control
- DO NOT commit, push, tag, or branch unless the user explicitly asks. Surface a summary of changes and let the user decide.
