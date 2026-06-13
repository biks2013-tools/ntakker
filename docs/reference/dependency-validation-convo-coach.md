---
status: clean
mode: fix
package_manager: npm
ecosystem: node
iterations_run: 1
deprecations_initial: 0
deprecations_final: 0
vulnerabilities_initial: 0
vulnerabilities_final: 0
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool/tools/convo-coach
validated_at: 2026-05-02T09:59:29Z
last_validated_commit: cb14c7cd11c2d3a2c89740637d81e32171e5af22
---

# Dependency Validation — convo-coach

## 1. Summary

The `convo-coach` TypeScript tool passed all validation checks on the first iteration. npm `install` produced zero deprecation warnings, `npm audit` reported zero vulnerabilities across all 51 packages (17 prod, 34 dev, 27 optional, 1 peer), and `npm run build` compiled with zero TypeScript errors or warnings. No replacements were applied; no manual review items remain. The dependency tree is clean.

## 2. Initial State

`npm install` (iteration 1) produced no deprecation warnings. All ten direct dependencies resolved cleanly:

| Package | Current | Wanted | Latest | Scope | Deprecated? | Severity |
|---|---|---|---|---|---|---|
| `ai` | 6.0.174 | 6.0.174 | — | direct/prod | No | — |
| `@ai-sdk/openai` | 3.0.58 | 3.0.58 | — | direct/prod | No | — |
| `@ai-sdk/anthropic` | 3.0.74 | 3.0.74 | — | direct/prod | No | — |
| `@ai-sdk/google` | 3.0.67 | 3.0.67 | — | direct/prod | No | — |
| `@ai-sdk/azure` | 3.0.59 | 3.0.59 | — | direct/prod | No | — |
| `@ai-sdk/openai-compatible` | 2.0.45 | 2.0.45 | — | direct/prod | No | — |
| `js-tiktoken` | 1.0.21 | 1.0.21 | — | direct/prod | No | — |
| `typescript` | 5.9.3 | 5.9.3 | 6.0.3* | direct/dev | No | — |
| `tsx` | 4.21.0 | 4.21.0 | — | direct/dev | No | — |
| `@types/node` | 22.19.17 | 22.19.17 | 25.6.0* | direct/dev | No | — |

_* Latest column shows the global latest across ALL major versions, not a recommended upgrade. See note below._

### Note on "outdated" output

`npm outdated` reported two packages as having a newer "latest":

- **`typescript`**: current `5.9.3` (latest in the `^5.6.0` range) vs global latest `6.0.3`. TypeScript 6.0 is a **major-version** release. The `^5.6.0` pin is intentional and correct; `5.9.3` is the newest release within the `5.x` line. Not deprecated — no action required.
- **`@types/node`**: current `22.19.17` (latest in the `^22.0.0` range) vs global latest `25.6.0`. Node types 25.x targets Node 25 runtimes. The `^22.0.0` pin matches the project's `"engines": { "node": ">=20" }` policy. `22.19.17` is the newest in the `22.x` line. Not deprecated — no action required.

Both packages were verified against the npm registry: neither the installed version nor any version within the pinned range carries a `deprecated` flag.

## 3. Replacements Applied

No replacements were applied. The deprecation list was empty after Step 2, so the fix loop had nothing to do.

## 4. Manual Review Needed

None. All ten direct dependencies are current, undeprecated, and free of security advisories. No transitive deprecations were detected. No items require human follow-up.

## 5. Security Audit

`npm audit --json` (iteration 1, exit code 0):

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Moderate | 0 |
| Low | 0 |
| Info | 0 |
| **Total** | **0** |

Packages audited: 51 (17 prod, 34 dev, 27 optional, 1 peer).

No advisories, no fixed-version recommendations. Audit is clean.

## 6. Final State

The `convo-coach` dependency tree is **clean**. Summary:

- 0 deprecations (initial: 0, final: 0)
- 0 vulnerabilities (initial: 0, final: 0)
- Build: `npm run build` exits 0 with zero TypeScript errors or warnings
- Peer dependencies: no conflicts, no UNMET peers
- The two "major-version-ahead" entries in `npm outdated` (`typescript@6`, `@types/node@25`) are expected and intentional version pin decisions — not issues

Status parity with `tools/dual-transcript-merger/` (previously audited clean): **achieved**.

## 7. Commands Run

| # | Command | Working Directory | Exit Code |
|---|---|---|---|
| 1 | `node --version` | `tools/convo-coach` | 0 (v25.9.0) |
| 2 | `npm --version` | `tools/convo-coach` | 0 (11.12.1) |
| 3 | `npm install` | `tools/convo-coach` | 0 |
| 4 | `npm outdated --json` | `tools/convo-coach` | 1 (non-zero when outdated entries exist; no deprecated packages) |
| 5 | `npm audit --json` | `tools/convo-coach` | 0 (0 vulnerabilities) |
| 6 | `npm install --dry-run` (deprecation grep) | `tools/convo-coach` | 0 (no deprecation warnings found) |
| 7 | `npm ls --json` | `tools/convo-coach` | 0 |
| 8 | `npm ls` (peer/warn grep) | `tools/convo-coach` | 0 (no peer issues) |
| 9 | `npm info <pkg> deprecated` (×10 packages) | `tools/convo-coach` | 0 (all returned empty — no deprecated flag) |
| 10 | `npm run build` | `tools/convo-coach` | 0 |
