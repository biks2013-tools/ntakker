---
status: completed
mode: write-and-run
scope_slug: convo-coach-config
language: TypeScript
framework: node:test (tsx runner)
test_command_full: npm test
test_command_scope: npx tsx --test test/config.test.ts
test_dir: tools/convo-coach/test
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool/tools/convo-coach
test_files_owned:
  - tools/convo-coach/test/config.test.ts
tests_added: 56
tests_updated: 0
tests_run: 56
tests_passed: 56
tests_failed: 0
implementation_gaps: 0
built_at: 2026-05-02T12:00:00Z
last_built_commit: cb14c7cd11c2d3a2c89740637d81e32171e5af22
---

# Test Build — convo-coach config four-tier env resolver

## 1. Summary

Status: completed. The four-tier configuration resolver in `tools/convo-coach/src/config.ts`
was exercised end-to-end. Framework is `node:test` driven by `tsx` (the project's standard).
56 new tests were added in `tools/convo-coach/test/config.test.ts`. All 56 passed on the
first run with zero failures and zero implementation gaps identified.

---

## 2. Scope Resolved

**Source file:** `tools/convo-coach/src/config.ts`

**In-scope public symbols:**

- `loadConfig(cliArgs: CliArgs, opts?: LoadConfigOptions): ResolvedConfig` — the main
  four-tier resolver. Exported.
- `__test.parseDotEnv(text: string): Record<string, string>` — hand-rolled `.env`
  parser. Exported via the frozen `__test` namespace for unit testing.
- `__test.ALIAS_MAP` — canonical-to-alias mapping (5 alias pairs). Exported via `__test`.
- `__test.RECOGNISED_KEYS` — `ReadonlySet<ConfigKey>` of all env-var keys the resolver
  reads. Exported via `__test`.

**Supporting types (read-only):** `CliArgs`, `ConfigKey`, `ProvenanceTier`, `ResolvedConfig`
imported from `src/types.ts`.

---

## 3. Existing Coverage

None. No file matching `*.test.ts`, `*.spec.ts`, or `test_*.ts` existed for
`config.ts` prior to this build. The other test files in `tools/convo-coach/test/`
(`budget-smoke`, `integration-smoke`, `llm-factory-smoke`, `prompt-smoke`,
`transcript-smoke`) import `../src/config.js` indirectly only through
`loadConfig` calls embedded in the main orchestrator — they do not unit-test
the config module's tier ordering, alias resolution, `.env` parsing, or
bootstrap behaviour.

---

## 4. Plan

| # | target_symbol | category | test_file | test_name | intent |
|---|---|---|---|---|---|
| 1 | parseDotEnv | unit | config.test.ts | comment lines starting with # are skipped | Proves `#`-prefixed lines produce no output key |
| 2 | parseDotEnv | unit | config.test.ts | blank lines are skipped without error | Proves empty lines are silently ignored |
| 3 | parseDotEnv | unit | config.test.ts | double-quoted values have quotes stripped | Proves `KEY="v"` → `v` |
| 4 | parseDotEnv | unit | config.test.ts | single-quoted values have quotes stripped | Proves `KEY='v'` → `v` |
| 5 | parseDotEnv | unit | config.test.ts | mismatched quotes are left intact | Proves `KEY="v'` is not stripped |
| 6 | parseDotEnv | error_path | config.test.ts | lines without = are ignored (no crash) | Proves parser does not throw on malformed lines |
| 7 | parseDotEnv | unit | config.test.ts | key-only line followed by equals yields empty string | Proves `KEY=` → `''` (not undefined) |
| 8 | parseDotEnv | unit | config.test.ts | trailing comment after value is NOT stripped | Documents intentional simple-parser behaviour |
| 9 | parseDotEnv | unit | config.test.ts | KEY with surrounding whitespace is trimmed | Proves `KEY  =  v  ` → `v` |
| 10 | parseDotEnv | unit | config.test.ts | Windows CRLF line endings are handled | Proves `\r\n` split works correctly |
| 11 | parseDotEnv | unit | config.test.ts | multiple key=value pairs are all parsed | Proves output map contains all valid pairs |
| 12 | loadConfig / alias | unit | config.test.ts | ANTHROPIC_FOUNDRY_API_KEY fills AZURE_AI_INFERENCE_KEY when canonical unset | Core alias spec |
| 13 | loadConfig / alias | unit | config.test.ts | canonical AZURE_AI_INFERENCE_KEY wins over alias | Canonical-wins invariant |
| 14 | loadConfig / alias | unit | config.test.ts | ANTHROPIC_FOUNDRY_ENDPOINT fills AZURE_AI_INFERENCE_ENDPOINT | Endpoint alias |
| 15 | loadConfig / alias | unit | config.test.ts | canonical AZURE_AI_INFERENCE_ENDPOINT wins over alias | Canonical-wins invariant |
| 16 | loadConfig / alias | unit | config.test.ts | LITELLM_API_BASE fills LITELLM_PROXY_URL | LiteLLM URL alias |
| 17 | loadConfig / alias | unit | config.test.ts | canonical LITELLM_PROXY_URL wins over LITELLM_API_BASE | Canonical-wins invariant |
| 18 | loadConfig / alias | unit | config.test.ts | LITELLM_API_KEY fills LITELLM_MASTER_KEY | LiteLLM key alias |
| 19 | loadConfig / alias | unit | config.test.ts | canonical LITELLM_MASTER_KEY wins over LITELLM_API_KEY | Canonical-wins invariant |
| 20 | loadConfig / alias | unit | config.test.ts | GEMINI_API_KEY fills GOOGLE_API_KEY | Google alias |
| 21 | loadConfig / alias | unit | config.test.ts | canonical GOOGLE_API_KEY wins over GEMINI_API_KEY | Canonical-wins invariant |
| 22 | loadConfig / alias | unit | config.test.ts | requesting alias key directly returns own value | Alias keys are also first-class RECOGNISED_KEYS |
| 23 | ALIAS_MAP | unit | config.test.ts | ALIAS_MAP canonical-to-alias mapping is correct for all five alias pairs | Static map spec verification |
| 24 | loadConfig / tiers | unit | config.test.ts | tier-1 shell env value used when no higher tier sets the key | Tier-1 baseline |
| 25 | loadConfig / tiers | unit | config.test.ts | empty string in shell env treated as unset | Empty-string guard |
| 26 | loadConfig / tiers | unit | config.test.ts | tier-2 tool-env overrides tier-1 shell env | Tier-2 precedence |
| 27 | loadConfig / tiers | unit | config.test.ts | tier-3 cwd-env overrides tier-2 tool-env | Tier-3 precedence |
| 28 | loadConfig / tiers | unit | config.test.ts | tier-3 cwd-env without tool-env overrides tier-1 shell | Tier-3 over tier-1 |
| 29 | loadConfig / tiers | unit | config.test.ts | tier-4 CLI flag overrides all lower tiers for COACH_PROVIDER | Tier-4 highest priority |
| 30 | loadConfig / tiers | unit | config.test.ts | no CLI flag for OPENAI_API_KEY — cwd-env wins | Non-CLI key topped at tier-3 |
| 31 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | cliArgs.provider → COACH_PROVIDER cli provenance | provider mapping |
| 32 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | cliArgs.model → COACH_MODEL cli provenance | model mapping |
| 33 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | cliArgs.recordingsDir → MACREC_RECORDINGS_DIR cli provenance | recordingsDir mapping |
| 34 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | cliArgs.debounce → COACH_DEBOUNCE cli provenance | debounce mapping |
| 35 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | cliArgs.onOverflow → COACH_ON_OVERFLOW cli provenance | onOverflow mapping |
| 36 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | cliArgs.systemPrompt → COACH_SYSTEM_PROMPT_PATH cli provenance | systemPrompt mapping |
| 37 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | empty string cliArgs treated as absent | Empty-CLI guard |
| 38 | loadConfig / CLI_OVERRIDES | unit | config.test.ts | all six CLI override keys verified via observable behaviour | Complete CLI coverage |
| 39 | loadConfig / provenance | unit | config.test.ts | provenance undefined when key not set in any tier | No-hit case |
| 40 | loadConfig / provenance | unit | config.test.ts | provenance is shell when only in process.env | Shell tier reporting |
| 41 | loadConfig / provenance | unit | config.test.ts | provenance is tool-env when in ~/.tool-agents/convo-coach/.env | Tool-env tier reporting |
| 42 | loadConfig / provenance | unit | config.test.ts | provenance is cwd-env when in local .env (overrides tool-env) | Cwd-env tier reporting |
| 43 | loadConfig / provenance | unit | config.test.ts | provenance is cli when CLI flag passed | CLI tier reporting |
| 44 | loadConfig / provenance | unit | config.test.ts | alias provenance reflects tier that set the alias key | Shell-alias provenance |
| 45 | loadConfig / provenance | unit | config.test.ts | alias provenance upgrades to cwd-env when alias is in local .env | Cwd-alias provenance |
| 46 | bootstrapToolAgentsDir | unit | config.test.ts | loadConfig creates ~/.tool-agents/convo-coach/ when missing | Bootstrap creation |
| 47 | bootstrapToolAgentsDir | unit | config.test.ts | bootstrapped directory has mode 0o700 | Correct permission bits |
| 48 | bootstrapToolAgentsDir | unit | config.test.ts | loadConfig is idempotent — calling it twice does not fail | Idempotency |
| 49 | bootstrapToolAgentsDir | unit | config.test.ts | bootstrap does NOT create the .env file | .env seeded out-of-band only |
| 50 | loadConfig / get() | config_validation | config.test.ts | get() returns undefined for an unset key — no default substituted | No-fallback rule for credentials |
| 51 | loadConfig / get() | config_validation | config.test.ts | get() returns undefined for unset aliased key when both absent | No-fallback rule for aliased keys |
| 52 | loadConfig / get() | config_validation | config.test.ts | get() returns undefined for COACH_PROVIDER when unset | No-fallback rule for COACH_PROVIDER |
| 53 | loadConfig / opts.cwd | unit | config.test.ts | opts.cwd is used instead of process.cwd() when supplied | Explicit cwd option |
| 54 | loadConfig / opts.cwd | unit | config.test.ts | opts.cwd omitted → process.cwd() used | Implicit cwd fallback |
| 55 | RECOGNISED_KEYS | unit | config.test.ts | all alias keys (canonical + alias) are in RECOGNISED_KEYS | Completeness check |
| 56 | RECOGNISED_KEYS | unit | config.test.ts | RECOGNISED_KEYS contains all eight standard provider keys | Provider-key completeness |

---

## 5. Files Owned

| File | Reason |
|---|---|
| `tools/convo-coach/test/config.test.ts` | new — created from scratch; no prior file existed |

---

## 6. Test Run Results

**Command:** `npx tsx --test test/config.test.ts`
**Exit code:** 0

```
tests 56  |  suites 9  |  pass 56  |  fail 0  |  cancelled 0  |  skipped 0  |  todo 0
duration_ms 162
```

All 56 tests passed. No failures.

---

## 7. Implementation Gaps

None. All tests passed and no divergence between the implementation and the specified
behaviour was observed.

---

## 8. Manual Review Needed

**None.**

Notes:

- The `process.env.HOME` redirect strategy was chosen over backing up the real
  `~/.tool-agents/convo-coach/` because it is safer (no risk of corrupting the
  real directory if a test aborts) and does not require root or special permissions.
  Every test group restores the original HOME in its `afterEach` hook.
- The LSP diagnostic tool (`mcp__cclsp__get_diagnostics`) could not inspect
  the test file because it requires a global TypeScript install and the project
  uses a local devDependency only. The `npx tsx --test` run is authoritative —
  `tsx` re-uses the project-local `typescript` install, so type errors surface
  as runtime failures. Zero failures were observed.
- Shared test infrastructure (`package.json` scripts, `tsconfig.json`) was not
  modified. The test file runs cleanly with the existing `npm test` script
  (`node --test --import tsx test/*.test.ts`) and with the scope-only invocation
  (`npx tsx --test test/config.test.ts`).

---

## 9. Commands Run

| # | Command | Exit code |
|---|---|---|
| 1 | `node --version` | 0 |
| 2 | `npx tsx --version` | 0 |
| 3 | `ls /Users/giorgosmarinos/.tool-agents/convo-coach/` | 0 |
| 4 | `npx tsx --test test/config.test.ts` (from `tools/convo-coach/`) | 0 |
