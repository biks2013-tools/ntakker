---
status: clean
mode: report-only
package_manager: swift-package-manager
ecosystem: swift
iterations_run: 0
deprecations_initial: 0
deprecations_final: 0
vulnerabilities_initial: 0
vulnerabilities_final: 0
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
validated_at: 2026-04-27T00:00:00Z
last_validated_commit: cc462530ec8148eee49ae3522d7ddd384756f762
---

# Dependency Validation — macrec / Live Transcription Phase (Phase F)

## Ecosystem note

This project uses Swift Package Manager (SPM). The team-workflow dependency-validator agent supports npm, yarn, pnpm, bun, uv, poetry, pipenv, and pip ecosystems only. SPM is not in that supported set. Per the notes accompanying this task, this audit was performed manually using `swift package show-dependencies --format json`, `swift package describe`, `Package.resolved`, and direct GitHub API queries for release status and security advisories. The `mode: report-only` constraint was honoured: no manifest files were modified, and `swift package resolve` was the only command that could potentially write to the `.build` directory (it is scoped to the build cache, not to user-owned source files).

---

## 1. Summary

The project's SwiftPM dependency tree after Phase F (Gemini Live transcription provider implementation) remains **clean**. The dependency count is unchanged from the Phase A baseline: two direct dependencies (`apple/swift-argument-parser` at 1.7.1, `apple/swift-log` at 1.12.0), zero transitive dependencies. Phase F was implemented exclusively via Apple system frameworks (`Foundation.URLSessionWebSocketTask`, `Network.NWPathMonitor`) without adding any new SwiftPM packages, confirming the constraint stated in `refined-request-live-transcription.md` §Constraints. No deprecation warnings were found, no security advisories exist for either package, and both revision SHAs recorded in `Package.resolved` match the corresponding GitHub release tags exactly.

---

## 2. Initial State

### 2a. Resolved dependency tree

Output of `swift package show-dependencies --format json` (condensed):

```
recording-tool (unspecified) [local]
├── swift-argument-parser  1.7.1   (leaf — no transitive deps)
└── swift-log              1.12.0  (leaf — no transitive deps)
```

Both packages are flat leaves. The `.build/checkouts/` directory contains exactly two entries (`swift-argument-parser`, `swift-log`), confirming the tree reported above.

### 2b. Direct dependency table

| Package | Manifest constraint | Resolved version | Resolved SHA (Package.resolved) | GitHub tag SHA | Match |
|---|---|---|---|---|---|
| `apple/swift-argument-parser` | `from: "1.5.0"` (< 2.0.0) | **1.7.1** | `626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b` | `626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b` | Yes |
| `apple/swift-log` | `from: "1.5.4"` (< 2.0.0) | **1.12.0** | `5073617dac96330a486245e4c0179cb0a6fd2256` | `5073617dac96330a486245e4c0179cb0a6fd2256` | Yes |

SHA cross-reference method: `GET https://api.github.com/repos/apple/<pkg>/git/refs/tags/<version>` → `.object.sha` compared byte-for-byte against `Package.resolved`'s `state.revision`. Both match exactly.

### 2c. Deprecation scan

| Package | Deprecated? | Evidence | Recommended replacement |
|---|---|---|---|
| `apple/swift-argument-parser` | No | GitHub repository `archived: false`, `disabled: false`. No deprecation text in README. Release 1.7.1 published 2026-03-20 (most recent stable). No deprecation warning emitted by `swift package resolve`. | N/A |
| `apple/swift-log` | No | GitHub repository `archived: false`, `disabled: false`. No deprecation text in README. Release 1.12.0 published 2026-04-14 (most recent stable). No deprecation warning emitted by `swift package resolve`. | N/A |

### 2d. Version currency

| Package | Resolved version | Latest stable at audit date | Gap | Action needed |
|---|---|---|---|---|
| `apple/swift-argument-parser` | 1.7.1 | **1.7.1** | None — pinned to current latest | None |
| `apple/swift-log` | 1.12.0 | **1.12.0** | None — pinned to current latest | None |

Both packages are pinned (via `Package.resolved`) to the latest stable release at the time of audit. The manifest's `from:` constraint allows future patch/minor updates up to (but not including) 2.0.0, so running `swift package update` after a future upstream release will bring in newer versions automatically without a manifest edit.

---

## 3. Replacements Applied

None. Mode is `report-only`; no modifications were made.

---

## 4. Manual Review Needed

**None.** No items require manual review.

The following observations are informational only and do not block Phase 10 (Integration Verifier):

### 4a. swift-log 1.12.0 — "Drop Swift 6.0" release note

The 1.12.0 release notes include the entry "Drop Swift 6.0 by @rnro". This refers to the package's own CI/development toolchain support (the package's `Package.swift` now requires swift-tools-version:6.2 for building the library itself), not to any constraint imposed on downstream consumers of the `Logging` product. The `macrec` project's own `Package.swift` declares `swift-tools-version:5.9` and the project builds cleanly under Swift 6.3.1 (the installed toolchain). No action required.

### 4b. swift-log traits feature (new in 1.9+)

`swift-log` 1.9 and later expose an optional `traits` system (`MaxLogLevelDebug`, `MaxLogLevelInfo`, etc.) for compile-time log-level elision. The `macrec` project does not pass any `traits:` array in its `Package.swift`, which is correct — the default (all log levels available) applies. This is not a concern but is noted for any future performance-tuning work: enabling `MaxLogLevelInfo` in release builds would eliminate `debug`/`trace` call overhead at compile time.

### 4c. swift-log 1.12.0 — `InMemoryLogging` product

`swift-log` 1.12.0 ships a new `InMemoryLogging` library product. The `macrec` project does not import it. If test targets switch to it in a future phase, no manifest change is needed — it is already available in the resolved version.

---

## 5. Security Audit

Security advisory check was performed against two sources:

### 5a. GitHub Security Advisories (GHSA)

`GET https://api.github.com/repos/apple/<pkg>/security-advisories`

| Package | Advisories returned |
|---|---|
| `apple/swift-argument-parser` | **0** |
| `apple/swift-log` | **0** |

### 5b. OSV.dev (Open Source Vulnerabilities database)

Query: `POST https://api.osv.dev/v1/query` with `{"package": {"name": "<pkg>", "ecosystem": "SwiftURL"}}`

| Package | Vulnerabilities returned |
|---|---|
| `apple/swift-argument-parser` | **0** |
| `apple/swift-log` | **0** |

### 5c. Apple system framework security posture

The transcription module added in Phase F introduces two previously unused Apple system frameworks:

| Framework | Added by | Security surface | Notes |
|---|---|---|---|
| `Network` (`Network.framework`) | `Transcription/Networking/NetworkPathObserver.swift`, `Transcription/Networking/WebSocketSession.swift` | Path monitoring (`NWPathMonitor`) — read-only, no outbound network calls from the observer itself | `NWPathMonitor` is a passive observer; it does not open connections. No elevated TCC permission required. |
| `Foundation` (`URLSessionWebSocketTask`) | `Transcription/Networking/URLSessionWebSocketTransport.swift`, `Transcription/Providers/GeminiLiveTranscriptionProvider.swift` | Outbound WebSocket (`wss://`) to `generativelanguage.googleapis.com` | Requires `com.apple.security.network.client` entitlement if the binary is later sandboxed (currently unsigned/not sandboxed). Audio PCM bytes are transmitted; no PII metadata per NFR-20. TLS is handled by the OS TLS stack; no custom certificate pinning is implemented (acceptable for v1). |

These are Apple-provided OS frameworks, not third-party packages. They carry no deprecation or CVE risk within the macOS 14+ deployment target.

---

## 6. Final State

**Status: clean.**

- Direct SwiftPM dependencies: 2 (unchanged from Phase A baseline).
- Transitive SwiftPM dependencies: 0 (unchanged).
- Deprecated packages: 0.
- Security advisories: 0.
- Both resolved versions are current latest-stable at audit date.
- Both resolved SHAs match their GitHub release tags exactly — no tampering or SHA drift.
- The build (`swift build --configuration debug`) completes with zero errors and zero warnings in 0.08 s (incremental; all artifacts already built).
- Phase F's networking implementation (`URLSessionWebSocketTask`, `NWPathMonitor`) adds no new SwiftPM dependencies, confirming the constraint in `refined-request-live-transcription.md` §Constraints/Technical.

**Phase 10 (Integration Verifier): READY — no dependency concerns.**

---

## 7. Commands Run

All commands were run in `report-only` mode. No source files were modified. The `.build/` directory is a build cache and was not cleared.

| # | Command | Exit code | Notes |
|---|---|---|---|
| 1 | `swift --version` | 0 | Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102), target arm64-apple-macosx26.0 |
| 2 | `swift package show-dependencies --format json` | 0 | Confirmed flat two-package tree; output recorded verbatim in §2a. |
| 3 | `swift package describe --type json` | 0 | Confirmed manifest structure, product list, and target list; no workspace declarations found. |
| 4 | `swift package resolve` | 0 | Resolved against existing lockfile; no changes to `Package.resolved`. |
| 5 | `swift build --configuration debug` | 0 | Build complete in 0.08 s (incremental); zero warnings, zero errors. |
| 6 | `GET https://api.github.com/repos/apple/swift-argument-parser/releases/latest` | HTTP 200 | Latest release: 1.7.1, published 2026-03-20. |
| 7 | `GET https://api.github.com/repos/apple/swift-log/releases/latest` | HTTP 200 | Latest release: 1.12.0, published 2026-04-14. |
| 8 | `GET https://api.github.com/repos/apple/swift-argument-parser/security-advisories` | HTTP 200 | 0 advisories returned. |
| 9 | `GET https://api.github.com/repos/apple/swift-log/security-advisories` | HTTP 200 | 0 advisories returned. |
| 10 | `GET https://api.github.com/repos/apple/swift-argument-parser` | HTTP 200 | `archived: false`, `disabled: false`. |
| 11 | `GET https://api.github.com/repos/apple/swift-log` | HTTP 200 | `archived: false`, `disabled: false`. |
| 12 | `GET https://api.github.com/repos/apple/swift-argument-parser/git/refs/tags/1.7.1` | HTTP 200 | Tag object SHA: `626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b`. Matches `Package.resolved`. |
| 13 | `GET https://api.github.com/repos/apple/swift-log/git/refs/tags/1.12.0` | HTTP 200 | Tag object SHA: `5073617dac96330a486245e4c0179cb0a6fd2256`. Matches `Package.resolved`. |
| 14 | `POST https://api.osv.dev/v1/query` (swift-argument-parser) | HTTP 200 | 0 vulnerabilities returned. |
| 15 | `POST https://api.osv.dev/v1/query` (swift-log) | HTTP 200 | 0 vulnerabilities returned. |
| 16 | `GET https://api.github.com/repos/apple/swift-argument-parser/releases?per_page=5` | HTTP 200 | Recent releases inspected for deprecation notices; none found. |
| 17 | `GET https://api.github.com/repos/apple/swift-log/releases?per_page=5` | HTTP 200 | Recent releases inspected; "Drop Swift 6.0" in 1.12.0 noted and assessed in §4a. |
| 18 | `grep -rn "^import " Sources/MacrecCore/Transcription/` | 0 | Import inventory for Phase F transcription module — all framework references are Apple system frameworks or existing SPM products. |

---

*Report written by the dependency-validator agent in `report-only` mode. No project files were modified.*
