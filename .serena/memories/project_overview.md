# recording-tool — Project Overview

## Status
Greenfield project (only `CLAUDE.md` exists, no source code yet).

## Purpose
A macOS-only command-line / menu-bar tool that records:
1. **System audio** (audio playing through any application: Music, Spotify, Zoom, Teams, browser, etc.) via `ScreenCaptureKit` (macOS 13+).
2. **Microphone audio** via `AVFoundation`.

The two streams can be saved as separate tracks or mixed into a single file.

## Tech stack
- **Language**: **Swift** (approved exception to the project's "TypeScript only" rule — see CLAUDE.md "Project Memory / Approved Exceptions" → Exception 001).
- **Build system**: Swift Package Manager (SPM) — `Package.swift`.
- **Frameworks**: `ScreenCaptureKit`, `AVFoundation`, `CoreAudio`, `AVFAudio`, `Foundation`.
- **Test framework**: XCTest (default for SPM).
- **Minimum platform**: macOS 13.0 (Ventura) — required by `ScreenCaptureKit` system-audio capture.

## Conventions
- File layout follows SPM conventions: `Sources/<TargetName>/`, `Tests/<TargetName>Tests/`.
- Code style: standard Swift API Design Guidelines (camelCase methods, UpperCamelCase types).
- Configuration follows the project's CLAUDE.md env-variable resolution chain (shell env → `~/.tool-agents/<tool-name>/.env` → local `.env` → CLI flags), implemented via Swift `ProcessInfo` + `FileManager` rather than Node `process.env`.
- No fallback values for missing config — raise descriptive errors.
- Database naming convention (singular tables) — N/A for this project, no DB.

## Suggested commands (will be populated as project takes shape)
- `swift build` — compile
- `swift test` — run XCTest suites
- `swift run <executable>` — run the recorder
- `swift package generate-xcodeproj` — generate Xcode project (optional, for IDE)
- `swiftlint` (if added) — lint
- `swift-format` (if added) — format

## Documentation map
- `CLAUDE.md` — project rules + approved exceptions + Tools index
- `docs/design/project-design.md` — architecture (to be created)
- `docs/design/project-functions.md` — functional requirements (to be created)
- `docs/design/plan-NNN-*.md` — implementation plans
- `docs/design/configuration-guide.md` — config guide (to be created)
- `docs/tools/<tool-name>.md` — per-tool documentation
- `docs/reference/` — reference material (Apple docs excerpts, etc.)
- `docs/research/` — deep technical research outputs
- `test_scripts/` — ad-hoc test scripts
- `prompts/` — sequentially-numbered prompt files
- `Issues - Pending Items.md` — pending items / issues (to be created at root)

## Important
The full and authoritative project conventions live in `CLAUDE.md` at the project root. Read that file before any non-trivial change.
