---
status: completed
mode: write-and-run
scope_slug: convo-coach-args-autodetect
language: TypeScript
framework: node --test (with tsx loader)
test_command_full: cd tools/convo-coach && npm test
test_command_scope: cd tools/convo-coach && npx tsx --test test/args-autodetect.test.ts
test_dir: tools/convo-coach/test
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool/tools/convo-coach
test_files_owned:
  - tools/convo-coach/test/args-autodetect.test.ts
tests_added: 37
tests_updated: 0
tests_run: 37
tests_passed: 37
tests_failed: 0
implementation_gaps: 0
built_at: 2026-05-02T13:00:00Z
last_built_commit: cb14c7cd11c2d3a2c89740637d81e32171e5af22
---

# Test Build — convo-coach args & autodetect

## 1. Summary

Status: **completed**. Framework: `node --test` with `tsx` loader (matches the project's existing `npm test` script convention from `tools/convo-coach/package.json`). 37 tests were added across three `describe` suites covering `parseCliArgs`, `helpText`, and `autodetectLatestSidecar`. All 37 pass with 0 failures and 0 implementation gaps. No production source was modified.

## 2. Scope Resolved

Scope files and in-scope symbols:

- `tools/convo-coach/src/args.ts`
  - `parseCliArgs(argv: readonly string[]): CliArgs` — hand-rolled CLI parser, space-separated flags, no `=` syntax.
  - `helpText(): string` — full usage text, single source of truth for the CLI's `--help` output.
- `tools/convo-coach/src/transcript/autodetect.ts`
  - `autodetectLatestSidecar(recordingsDir: string): string` — tilde-expands the path, stat-checks it is a directory, scans top-level entries for `.jsonl` / `.txt`, returns absolute path of the newest by mtime.
  - `expandTilde(input: string): string` — module-private helper; tested transitively via `autodetectLatestSidecar`.

Supporting types read but not directly tested (owned by another agent):
- `tools/convo-coach/src/types.ts`: `UsageError`, `TranscriptError`, `PROVIDER_NAMES`, `OVERFLOW_STRATEGIES`, `CliArgs`.

## 3. Existing Coverage

Symbol → existing test files:

| Symbol | Pre-existing test file |
|---|---|
| `parseCliArgs` | none |
| `helpText` | none |
| `autodetectLatestSidecar` | none |

No prior test coverage existed for any of the three in-scope symbols. The five existing test files (`budget-smoke`, `integration-smoke`, `llm-factory-smoke`, `prompt-smoke`, `transcript-smoke`) do not reference `args.ts` or `autodetect.ts`.

## 4. Plan

| # | target_symbol | category | test_file | test_name | intent |
|---|---|---|---|---|---|
| 1 | parseCliArgs | unit | args-autodetect.test.ts | no args → returns empty object | Verifies all CliArgs fields are undefined when no argv supplied |
| 2 | parseCliArgs | unit | args-autodetect.test.ts | all flags set → all fields populated correctly | Verifies every supported flag maps to the right CliArgs field |
| 3 | parseCliArgs | unit | args-autodetect.test.ts | --help → help is true | Verifies `--help` sets the `help` boolean |
| 3b | parseCliArgs | unit | args-autodetect.test.ts | -h → help is true (short form) | Verifies `-h` short-form sets the same field |
| 4 | parseCliArgs | unit | args-autodetect.test.ts | --version → version is true | Verifies `--version` sets the `version` boolean |
| 4b | parseCliArgs | unit | args-autodetect.test.ts | -V → version is true (short form) | Verifies `-V` short-form sets the same field |
| 5 | parseCliArgs | error_path | args-autodetect.test.ts | unknown flag throws UsageError with the bad flag name | UsageError message must contain the offending flag |
| 5b | parseCliArgs | error_path | args-autodetect.test.ts | positional argument throws UsageError | Non-flag positional args are rejected |
| 6 | parseCliArgs | error_path | args-autodetect.test.ts | --provider invalid value throws UsageError listing all accepted providers | Error enumerates the 8 valid provider names |
| 6b | parseCliArgs | unit | args-autodetect.test.ts | all 8 provider names are accepted without error | Exhaustive happy-path coverage for all ProviderName values |
| 7 | parseCliArgs | error_path | args-autodetect.test.ts | --on-overflow invalid value throws UsageError listing accepted strategies | Error enumerates the 3 valid overflow strategies |
| 7b | parseCliArgs | unit | args-autodetect.test.ts | all overflow strategies are accepted without error | Exhaustive happy-path for all OverflowStrategy values |
| 8 | parseCliArgs | error_path | args-autodetect.test.ts | --transcript at end of argv with no value throws UsageError | Missing value for value-bearing flag is caught |
| 8b | parseCliArgs | error_path | args-autodetect.test.ts | --provider/--model/--on-overflow at end → UsageError | Covers three more value-bearing flags with same pattern |
| 9 | parseCliArgs | unit | args-autodetect.test.ts | equal-sign syntax --provider=openai falls into unknown-option path | Documents that parser is space-separated only; `=` syntax throws |
| 10 | parseCliArgs | unit | args-autodetect.test.ts | flags in arbitrary order are all parsed correctly | Flag order is irrelevant; all are captured |
| 10b | parseCliArgs | unit | args-autodetect.test.ts | repeated --model flag: last value wins | Final occurrence wins on duplicate flags |
| 11a | helpText | unit | args-autodetect.test.ts | helpText includes "convo-coach" as the tool name | Tool name present in help output |
| 11b | helpText | unit | args-autodetect.test.ts | helpText includes all flag names | Every long-form flag documented |
| 11c | helpText | unit | args-autodetect.test.ts | helpText includes the short-form flags -h and -V | Short forms documented |
| 11d | helpText | unit | args-autodetect.test.ts | helpText includes all 8 provider names | Provider list complete |
| 11e | helpText | unit | args-autodetect.test.ts | helpText includes all 3 overflow strategies | Overflow strategy list complete |
| 11f | helpText | unit | args-autodetect.test.ts | helpText is a non-empty string | Sanity check |
| A1 | autodetectLatestSidecar | error_path | args-autodetect.test.ts | empty directory → TranscriptError mentioning no candidates | Empty dir is rejected with a descriptive message |
| A2 | autodetectLatestSidecar | error_path | args-autodetect.test.ts | non-existent directory → TranscriptError | Missing directory path raises NO_INPUT (exit 66) |
| A3 | autodetectLatestSidecar | unit | args-autodetect.test.ts | single .jsonl file → returns its path | Happy-path with exactly one candidate |
| A4 | autodetectLatestSidecar | unit | args-autodetect.test.ts | multiple .jsonl and .txt → returns most-recently-modified | mtime ordering is correct; uses utimesSync for determinism |
| A5 | autodetectLatestSidecar | unit | args-autodetect.test.ts | tilde expansion ~/subpath resolves to homedir-based path | ~ expansion works correctly |
| A6 | autodetectLatestSidecar | unit | args-autodetect.test.ts | mixed file types: .m4a .wav .md ignored; .jsonl and .txt candidates | Non-transcript extensions are excluded |
| A6b | autodetectLatestSidecar | unit | args-autodetect.test.ts | .jsonl and .txt both present: newest by mtime wins | Both candidate extensions are equally eligible |
| A7 | autodetectLatestSidecar | error_path | args-autodetect.test.ts | regular file path (not a dir) → TranscriptError "not a directory" | Passing a file path is caught and reported clearly |
| A8 | autodetectLatestSidecar | unit | args-autodetect.test.ts | hidden .jsonl file is included as a candidate | Hidden files are NOT excluded (no filter in impl.) |
| A8b | autodetectLatestSidecar | unit | args-autodetect.test.ts | hidden vs visible: most-recently-modified wins regardless of visibility | mtime ordering applies to hidden files equally |
| A9 | autodetectLatestSidecar | error_path | args-autodetect.test.ts | directory with only unsupported extensions → TranscriptError | .m4a / .wav only → treated same as empty for candidates |
| A10 | autodetectLatestSidecar | unit | args-autodetect.test.ts | bare tilde ~ expands to homedir without "not a directory" error | Bare `~` is handled as a valid directory path |

## 5. Files Owned

| File | Reason |
|---|---|
| `tools/convo-coach/test/args-autodetect.test.ts` | new — created by this agent |

## 6. Test Run Results

Command: `cd tools/convo-coach && npx tsx --test test/args-autodetect.test.ts`
Exit code: `0`

```
▶ parseCliArgs
  ✔ no args → returns empty object (all fields undefined) (0.460084ms)
  ✔ all flags set → all fields populated correctly (0.073333ms)
  ✔ --help → help is true (0.030583ms)
  ✔ -h → help is true (short form) (0.030042ms)
  ✔ --version → version is true (0.032541ms)
  ✔ -V → version is true (short form) (0.02425ms)
  ✔ unknown flag throws UsageError with the bad flag name (0.146875ms)
  ✔ positional argument throws UsageError (0.047667ms)
  ✔ --provider with invalid value throws UsageError listing all accepted providers (0.073709ms)
  ✔ all 8 provider names are accepted without error (0.070292ms)
  ✔ --on-overflow with invalid value throws UsageError listing accepted strategies (0.054333ms)
  ✔ all overflow strategies are accepted without error (0.026333ms)
  ✔ --transcript at end of argv with no value throws UsageError (0.056833ms)
  ✔ --provider at end of argv with no value throws UsageError (0.0355ms)
  ✔ --model at end of argv with no value throws UsageError (0.03975ms)
  ✔ --on-overflow at end of argv with no value throws UsageError (0.047459ms)
  ✔ equal-sign syntax --provider=openai falls into unknown-option path (space-separated only) (0.040958ms)
  ✔ flags in arbitrary order are all parsed correctly (0.033ms)
  ✔ repeated --model flag: last value wins (0.019709ms)
✔ parseCliArgs (1.806375ms)
▶ helpText
  ✔ helpText includes "convo-coach" as the tool name (0.34425ms)
  ✔ helpText includes all flag names (0.040875ms)
  ✔ helpText includes the short-form flags -h and -V (0.024042ms)
  ✔ helpText includes all 8 provider names (0.026292ms)
  ✔ helpText includes all 3 overflow strategies (0.022417ms)
  ✔ helpText is a non-empty string (0.016541ms)
✔ helpText (0.524417ms)
▶ autodetectLatestSidecar
  ✔ empty directory → throws TranscriptError mentioning no candidates (0.474333ms)
  ✔ non-existent directory → throws TranscriptError (0.069333ms)
  ✔ directory with a single .jsonl file → returns that file path (0.23875ms)
  ✔ multiple .jsonl and .txt files → returns most-recently-modified (0.8595ms)
  ✔ tilde expansion: ~/subpath resolves to homedir-based path (0.179583ms)
  ✔ mixed file types: .m4a, .wav, .md are ignored; only .jsonl and .txt are candidates (0.30475ms)
  ✔ .jsonl and .txt both present: newest by mtime wins regardless of extension (0.207083ms)
  ✔ passing a regular file path (not a dir) → throws TranscriptError (0.161833ms)
  ✔ hidden .jsonl file is included as a candidate (no hidden-file filter in implementation) (0.142459ms)
  ✔ hidden vs visible: most recently modified file wins regardless of visibility (0.219416ms)
  ✔ directory with only unsupported extensions (.m4a, .wav) → TranscriptError (0.183709ms)
  ✔ bare tilde ~ is expanded to homedir() without throwing when dir exists (0.118958ms)
✔ autodetectLatestSidecar (4.653125ms)
ℹ tests 37
ℹ suites 3
ℹ pass 37
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 131.852542
```

## 7. Implementation Gaps

None. All 37 tests passed against the current implementation.

Notable behavioural findings documented in tests (not gaps, just clarifications):

- **Equal-sign syntax is not supported.** `--provider=openai` is treated as an unknown flag (`unknown option '--provider=openai'`) and throws `UsageError`. The parser is strictly space-separated. This is consistent with the hand-rolled switch-based design. Documented in test #9 so any future change in either direction is immediately visible.
- **Hidden files are included as candidates.** `autodetectLatestSidecar` has no hidden-file filter — it uses `entry.isFile()` only. A file like `.hidden-session.jsonl` is a valid candidate. Documented in test A8. This is the expected behaviour given that macrec sidecars could in principle be hidden (e.g. created by a script prefixing `.`).
- **`CliArgs.help` and `CliArgs.version` are `undefined` (not `false`) when the flags are not passed.** The `CliArgs` interface marks both as `readonly help?: boolean` (optional), so the absent case produces `undefined`. Tests assert `!result.help` (falsy) rather than `=== false` to stay accurate to the actual interface shape.

## 8. Manual Review Needed

None. All planned tests were written without touching shared test infrastructure. No `conftest.py`, `jest.config.*`, or shared setup files were required or modified.

The following minor items are noted for human awareness but do not block anything:

1. **Unhandled-rejection configuration.** The project's `package.json` `test` script (`node --test --import tsx test/*.test.ts`) does not pass `--unhandled-rejections=throw`. Node ≥20 defaults to `throw` for unhandled rejections, so this is acceptable for Node ≥20 (per the engine constraint). No action needed.
2. **`MACREC_RECORDINGS_DIR` naming.** As documented in `codebase-scan-convo-coach.md` §"CRITICAL FINDING", `MACREC_RECORDINGS_DIR` is a `convo-coach`-owned variable (not a native macrec env var). The autodetect tests pass the directory directly and do not test the env-var resolution chain — that belongs to the config tests (`tools/convo-coach/test/config.test.ts` owned by another agent).

## 9. Commands Run

| # | Command | Exit code |
|---|---|---|
| 1 | `cd tools/convo-coach && npx tsx --test test/args-autodetect.test.ts` | `0` |
| 2 | `cd tools/convo-coach && npx tsc --noEmit --allowImportingTsExtensions --module ES2022 --target ES2022 --moduleResolution Bundler --strict --skipLibCheck test/args-autodetect.test.ts` | `0` |
