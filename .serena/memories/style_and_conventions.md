# Style & Conventions — recording-tool

## Swift
- Follow Apple Swift API Design Guidelines: `UpperCamelCase` types, `lowerCamelCase` methods/properties.
- Swift Package Manager layout: `Sources/<Target>/…`, `Tests/<Target>Tests/…` — sibling, not nested.
- Swift language mode pinned to **5** in `Package.swift` (`swiftLanguageModes: [.v5]`); tools-version is 6.2 only because `.macOS(.v26)` requires it. Any per-target migration to Swift 6 strict concurrency must be deliberate.
- Deployment target: `macOS 26` (Tahoe) — required for `SpeechAnalyzer`. Code that requires earlier macOS must use `#available(macOS 26, *)` gating.
- TCC plists are embedded at link time via `-Xlinker -sectcreate __TEXT __info_plist Resources/<plist>`. CLI uses `Resources/Info.plist`, UI uses `Resources/NtakkerUI-Info.plist`. Bundle IDs MUST stay distinct: `com.local.ntakker-cli` vs `com.local.ntakker`.
- Tests use Swift Testing (not XCTest) with the `-F /Library/Developer/CommandLineTools/Library/Developer/Frameworks` workaround so they run without full Xcode.
- Capture / Encoding / Mixing / Transcription are sub-namespaces inside `NtakkerCore` — keep new code in the matching folder. UI domain logic (controllers, coordinators, generators) lives in `NtakkerUIKit`; AppKit/SwiftUI shell code lives in `Sources/ntakker/`.

## TypeScript (tools/*)
- Strict TS, ESM. Each tool has its own `package.json` with `prepare` / `postbuild` scripts that build to `dist/` and `chmod +x dist/cli.js`. `npm link` exposes the binary globally. No Yarn/PNPM.
- LLM access via Vercel AI SDK, with provider plug points for the 8 standard providers listed in CLAUDE.md.

## Configuration (CLAUDE.md authoritative)
- Resolution chain (low → high priority):
  1. Shell env (`process.env` for TS tools, `ProcessInfo.processInfo.environment` for Swift).
  2. `~/.tool-agents/<tool-name>/.env` (auto-created mode 0700, .env mode 0600 on first run).
  3. Local `.env`.
  4. CLI flags.
- **No fallbacks for missing config** (raise descriptive errors). Sole approved exception: `convo-coach`'s `COACH_PROVIDER` default to `azure-openai` (Exception 003 — provider selection only, NOT credentials).
- LLM env vars use vendor-canonical names — never tool-prefixed.

## Documentation rules (CLAUDE.md)
- Plans → `docs/design/plan-NNN-<slug>.md`.
- Per-tool docs → `docs/tools/<tool-name>.md`. CLAUDE.md "Tools" section references but does NOT contain full docs.
- Functional reqs → `docs/design/project-functions.md`.
- Architecture → `docs/design/project-design.md` (kept in sync with each design change).
- Issues / pending → `Issues - Pending Items.md` at project root, pending items first (most critical at top), completed items below.
- Test scripts → `test_scripts/` (create if missing).
- Prompts → `prompts/`, sequential numeric prefix.

## DB naming (if/when introduced)
- Singular table names (`Customer`, `Transaction`).
- Cross-reference tables plural on the "many" side (`CustomerTransactions`).
