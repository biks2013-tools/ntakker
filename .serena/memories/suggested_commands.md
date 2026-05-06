# Suggested Commands — recording-tool

## Swift build / run
- `swift build`                                    — debug build everything
- `swift build -c release --product macrec`        — release CLI
- `swift build -c release --product macrec-ui`     — release UI app binary (use packaging script for .app bundle)
- `swift run macrec --help`                        — debug-run CLI (attached terminal inherits TCC grants)
- `swift run macrec list-devices`
- `swift run macrec start --output ~/Recordings/test.m4a`
- `swift run macrec stop`                          — stop a detached recording started with `start --detach`
- `swift run macrec-ui`                            — debug-run UI from terminal (no Apple Cloud STT, no Dock)
- `.build/release/macrec --help`                   — release CLI binary
- `.build/release/macrec-ui`                       — raw release UI binary (no Apple Cloud STT)

## Packaging the UI as a real .app
- `bash scripts/package-macrec-ui-app.sh`          — builds dist/macrec-ui.app (ad-hoc signed)
- `SWIFT_CONFIG=debug bash scripts/package-macrec-ui-app.sh`  — faster iteration
- `CODESIGN_IDENTITY="Developer ID Application: …" bash scripts/package-macrec-ui-app.sh` — real identity
- `open dist/macrec-ui.app`
- `pkill -f '\.build/.*macrec-ui' || true`         — kill stale raw-CLI instance before relaunch

## Deploying to /Applications
- `pkill -x macrec-ui || true`
- `rm -rf /Applications/macrec-ui.app`
- `cp -R dist/macrec-ui.app /Applications/macrec-ui.app`
- `xattr -dr com.apple.quarantine /Applications/macrec-ui.app || true`
- `open /Applications/macrec-ui.app`

## System install of CLI
- `swift build -c release --product macrec`
- `sudo cp .build/release/macrec /usr/local/bin/macrec`

## Tests
- `swift test`                                     — runs Swift Testing suites in MacrecCoreTests, MacrecUITests
- `swift test --filter <pattern>`                  — narrow scope

## TS tools (npm)
Each tool builds via `npm run build` (`tsc`) and links via `npm link`:
- `cd tools/dual-transcript-merger && npm install && npm link`
- `cd tools/convo-coach && npm install && npm link`
- `npm unlink -g <tool-name>`                      — remove the global symlink

## Darwin / git utilities
- `ls -la`, `find`, `grep` work as standard. macOS uses BSD `sed`/`date` (use `gsed`/`gdate` from coreutils if GNU-flavoured flags are needed).
- `pbcopy` / `pbpaste` for clipboard.
- `git status`, `git diff`, `git log --oneline -20`.
- `gh pr create`, `gh pr view` (GitHub CLI).
- Project repo lives at `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool`, branch `master`.

## Lint / format
- No `swiftlint` / `swift-format` configuration in repo. None required by CI as of 2026-05-05.

## Provider env (read once, used everywhere)
Resolution chain (low → high priority): shell env → `~/.tool-agents/<tool-name>/.env` → local `.env` → CLI flags. Use vendor-canonical names: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `AZURE_OPENAI_*`, `OLLAMA_HOST`, `LITELLM_*`. Soniox / ElevenLabs / Gemini Live keys also read from the same chain.
