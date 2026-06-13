---
name: Swift exception for recording-tool
description: User approved Swift (not TypeScript) for the macOS audio recording tool because system-audio capture requires native ScreenCaptureKit + AVFoundation
type: project
originSessionId: 196cf397-8509-4b81-badf-c8a1858f4002
---
The `recording-tool` project (path: `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool`) is implemented in **Swift**, not TypeScript, despite the project CLAUDE.md's blanket "all tools in TypeScript" rule.

**Why:** The tool must capture macOS system audio (Music/Spotify/Zoom/Teams/browser output) plus the microphone. macOS 13+ requires `ScreenCaptureKit` (system audio) and `AVFoundation` (mic) — both native Apple frameworks with no first-class Node/TypeScript bindings. A TypeScript implementation would be a thin shim over a Swift helper anyway.

**How to apply:**
- This exception is recorded in the project's CLAUDE.md under "Project Memory / Approved Exceptions" → Exception 001 (date approved: 2026-04-26).
- Apply Swift equivalents of TypeScript conventions: `ProcessInfo.processInfo.environment` for env vars, `FileManager` for the `~/.tool-agents/<tool-name>/.env` durable defaults file, but the user-facing config-precedence behavior must be identical.
- The TypeScript rule still applies to any *other* tool added to this project unless similarly approved.
