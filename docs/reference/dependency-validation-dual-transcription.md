---
status: clean
mode: fix
package_manager: swift (SwiftPM)
ecosystem: swift
iterations_run: 1
deprecations_initial: 0
deprecations_final: 0
vulnerabilities_initial: 3
vulnerabilities_final: 0
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
validated_at: 2026-05-01T12:00:00Z
last_validated_commit: c2e7080d1c0400f67ea0fb78bd6fff3242cf40
---

# Dependency Validation — recording-tool (Dual Transcription Baseline)

## 1. Summary

This is a "confirm clean baseline" pass for the recording-tool SwiftPM project, initiated prior to plan-010 (dual-provider live transcription) implementation work. No deprecations were found. Three GitHub Security Advisories (GHSAs) exist against transitive dependencies (`swift-crypto`, `swift-asn1`, `yyjson`), but all three are fully remediated by the versions already pinned in `Package.resolved` — no version bumps or replacements are required. The dependency tree is clean.

---

## 2. Initial State

### Direct dependencies (Package.swift)

| Package | Declared constraint | Resolved version | Scope | Latest available |
|---|---|---|---|---|
| `swift-argument-parser` | `from: "1.5.0"` | 1.7.1 | direct | 1.7.1 |
| `swift-log` | `from: "1.5.4"` | 1.12.0 | direct | 1.12.0 |
| `argmax-oss-swift` | `exact: "0.18.0"` | 0.18.0 | direct | 0.18.0 (v0.18.0) |

### Transitive dependencies (from Package.resolved)

| Package | Resolved version | Pulled in by | Latest available |
|---|---|---|---|
| `swift-transformers` | 1.1.9 | `argmax-oss-swift` | 1.3.0 (*) |
| `swift-jinja` | 2.3.5 | `swift-transformers` | 2.3.5 |
| `swift-collections` | 1.4.1 | `swift-transformers`, `swift-jinja` | 1.4.1 |
| `swift-crypto` | 4.5.0 | `swift-transformers` | 4.5.0 |
| `swift-asn1` | 1.7.0 | `swift-crypto` | 1.7.0 |
| `yyjson` | 0.12.0 | `swift-transformers` | 0.12.0 |

(*) `swift-transformers` 1.3.0 is a newer minor release but is intentionally excluded by `argmax-oss-swift`'s upstream constraint `.upToNextMinor(from: "1.1.6")`, which caps resolution at < 1.2.0. SwiftPM correctly resolved to 1.1.9. This is not a defect — it is expected version pinning by the upstream dependency.

### Deprecation scan result

`swift package resolve` — exit code 0, stdout empty, stderr empty. No deprecation warnings.

`swift package update --dry-run` — exit code 0, output: "0 dependencies would change." All packages are already at the latest versions permitted by their declared constraints.

### Deprecation list

**None.** Zero deprecations found in install output, dry-run update, or build output.

---

## 3. Replacements Applied

No replacements were required. The mode was `fix`, but the validate step found no actionable deprecations. Step 4 was skipped.

---

## 4. Manual Review Needed

None. All findings were either clean or already-patched advisories (see Section 5).

**Note on `argmax-oss-swift` exact pin:** `Package.swift` pins `argmax-oss-swift` to `exact: "0.18.0"`. This is intentional (documented in the Package.swift comments: "Pinned to 0.18.0 to match the version used by the sibling notch project"). Future updates to argmax-oss-swift will require a deliberate manual version bump. This is not a defect — it is a policy decision.

---

## 5. Security Audit

Three GHSAs exist in the GitHub Advisory Database for packages in this dependency tree. All three are fully remediated by the currently pinned versions.

| GHSA | CVE | Package | Scope | Severity | Affected range | Patched in | Our version | Status |
|---|---|---|---|---|---|---|---|---|
| GHSA-9m44-rr2w-ppp7 | CVE-2026-28815 | `swift-crypto` | transitive (via `swift-transformers` → `argmax-oss-swift`) | medium | 4.0.0 – 4.3.0 | 4.3.1 | **4.5.0** | NOT VULNERABLE |
| GHSA-w8xv-rwgf-4fwh | CVE-2025-0343 | `swift-asn1` | transitive (via `swift-crypto` → `swift-transformers` → `argmax-oss-swift`) | low | < 1.3.0 | 1.3.1 | **1.7.0** | NOT VULNERABLE |
| GHSA-q4m7-9pcm-fpxh | (no CVE) | `yyjson` | transitive (via `swift-transformers` → `argmax-oss-swift`) | medium | <= 0.8.0 | (unspecified) | **0.12.0** | NOT VULNERABLE |

### Advisory summaries

**GHSA-9m44-rr2w-ppp7 (swift-crypto, medium):** X-Wing HPKE Decapsulation accepts malformed ciphertext length. The `decapsulate` function of `OpenSSLXWingPrivateKeyImpl` does not validate the length of the encapsulated key before passing it to a C FFI, which may read beyond the Swift buffer boundary (undefined behavior). Fixed in 4.3.1. Our pinned version is 4.5.0 — not affected.

**GHSA-w8xv-rwgf-4fwh / CVE-2025-0343 (swift-asn1, low):** Crash when parsing maliciously formed BER/DER. A `preconditionFailure` can be triggered by input that violates DER constraints that the parser assumes but does not enforce, allowing denial-of-service when parsing TLS certificates from unknown sources. No memory-safety issue; the crash is graceful. Fixed in 1.3.1. Our pinned version is 1.7.0 — not affected.

**GHSA-q4m7-9pcm-fpxh (yyjson, medium):** Double-free vulnerability in the pool allocator (`pool_malloc` / `pool_free` / `pool_realloc`). The `pool_free` function lacks loop checks and does not destroy pointers after freeing, potentially leading to Use-After-Free and arbitrary address writing, which combined with other operations could enable remote code execution. Affected range <= 0.8.0. Our pinned version is 0.12.0 — not affected.

---

## 6. Final State

The dependency tree is **clean**. Specifically:

- 0 deprecated packages (direct or transitive).
- 0 packages with unpatched security advisories.
- All direct dependencies are at the latest versions compatible with their declared version ranges.
- All transitive dependencies are at the latest versions permitted by the upstream constraints in the dependency graph.
- `swift package update --dry-run` confirmed "0 dependencies would change."
- The project is ready to proceed to plan-010 implementation (Dual Transcription Mode) without any dependency remediation work.

---

## 7. Commands Run

| # | Command | Working dir | Exit code | Notes |
|---|---|---|---|---|
| 1 | `swift --version` | /Users/giorgosmarinos/aiwork/coding-platform/recording-tool | 0 | Swift 6.3.1 (swiftlang-6.3.1.1.2, clang-2100.0.123.102); arm64-apple-macosx26.0 |
| 2 | `swift package resolve` | /Users/giorgosmarinos/aiwork/coding-platform/recording-tool | 0 | stdout empty, stderr empty — lockfile already in sync, no warnings |
| 3 | `swift package show-dependencies` | /Users/giorgosmarinos/aiwork/coding-platform/recording-tool | 0 | Full dependency tree printed; 9 packages total (3 direct, 6 transitive) |
| 4 | `swift package update --dry-run` | /Users/giorgosmarinos/aiwork/coding-platform/recording-tool | 0 | "0 dependencies would change." — all packages at latest compatible versions |
| 5 | `curl https://api.github.com/repos/apple/swift-argument-parser/security-advisories` | — | 0 | 0 advisories returned |
| 6 | `curl https://api.github.com/repos/apple/swift-log/security-advisories` | — | 0 | 0 advisories returned |
| 7 | `curl https://api.github.com/repos/apple/swift-collections/security-advisories` | — | 0 | 0 advisories returned |
| 8 | `curl https://api.github.com/repos/apple/swift-crypto/security-advisories` | — | 0 | 1 advisory: GHSA-9m44-rr2w-ppp7 (medium); our version 4.5.0 is beyond patched 4.3.1 |
| 9 | `curl https://api.github.com/repos/apple/swift-asn1/security-advisories` | — | 0 | 1 advisory: GHSA-w8xv-rwgf-4fwh (low); our version 1.7.0 is beyond patched 1.3.1 |
| 10 | `curl https://api.github.com/repos/huggingface/swift-transformers/security-advisories` | — | 0 | 0 advisories returned |
| 11 | `curl https://api.github.com/repos/huggingface/swift-jinja/security-advisories` | — | 0 | 0 advisories returned |
| 12 | `curl https://api.github.com/repos/ibireme/yyjson/security-advisories` | — | 0 | 1 advisory: GHSA-q4m7-9pcm-fpxh (medium); our version 0.12.0 is beyond affected range (<= 0.8.0) |
| 13 | `curl https://api.github.com/repos/argmaxinc/argmax-oss-swift/security-advisories` | — | 0 | 0 advisories returned |
| 14 | `curl https://raw.githubusercontent.com/argmaxinc/argmax-oss-swift/<sha>/Package.swift` | — | 0 | Verified argmax-oss-swift uses `.upToNextMinor(from: "1.1.6")` for swift-transformers, explaining why 1.3.0 is not resolved |
| 15 | `curl https://api.github.com/repos/argmaxinc/argmax-oss-swift/releases` | — | 0 | Latest release is v0.18.0 — confirms our exact pin is current |

---

## Anomalies

None. Lockfile and manifest are in sync. No network failures encountered.

---

## Context

This validation was conducted as a pre-implementation baseline for **plan-010: Dual-Provider Live Transcription Mode** (Apple On-Device English + Apple Cloud Greek). Per the plan-010 refined request (`refined-request-dual-transcription.md`), plan-010 introduces **no new SwiftPM dependencies** — it uses only system frameworks (`Speech`, `AVFoundation`) already part of the macOS 26 deployment baseline. This validation confirms there are no existing dependency issues that plan-010 implementation would compound.
