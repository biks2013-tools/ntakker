---
project: recording-tool
ecosystem: swift-package-manager
status: clean
audited_at: 2026-04-26
mode: report-only
package_manager: swift-package-manager
total_direct_deps: 2
total_transitive_deps: 0
deprecated_count: 0
security_advisories: 0
---

# Dependency Validation — recording-tool

## Why this is a manual report

The team-workflow's `dependency-validator` subagent supports
`npm / yarn / pnpm / bun / uv / poetry / pipenv / pip` only. Swift
Package Manager (SPM) is not in its supported ecosystem list, so the
audit was performed by the orchestrator using `swift package
show-dependencies` and `Package.resolved`.

## Direct dependencies

Both SPM dependencies are **first-party Apple libraries** with active
maintenance, broad adoption, and Apache 2.0 licensing.

| Package | Version pinned | Repository | License | Status |
|---|---|---|---|---|
| `apple/swift-argument-parser` | **1.7.1** | https://github.com/apple/swift-argument-parser | Apache-2.0 | Maintained |
| `apple/swift-log` | **1.12.0** | https://github.com/apple/swift-log | Apache-2.0 | Maintained |

## Transitive dependencies

Both packages are leaf nodes — they pull in **no transitive
dependencies**. `swift package show-dependencies` reports a flat tree.

## Deprecation check

- **swift-argument-parser 1.7.1**: latest stable as of audit date.
  No deprecation notice on the repository, no archived issues warning
  about the version.
- **swift-log 1.12.0**: latest stable as of audit date. No deprecation
  notice.

## Security advisory check

- No advisories on either package's GitHub Security tab as of audit
  date.
- Neither package transitively imports anything network-facing
  (swift-argument-parser is pure Swift; swift-log is a logging façade
  with the project using `StreamLogHandler.standardError` only).
- No third-party C / Objective-C dependencies.

## Apple framework usage

While not "dependencies" in the SPM sense, the project links against
the following Apple frameworks via `import` statements. Apple's
deployment-target rules apply (macOS 14+):

| Framework | Used in | Notes |
|---|---|---|
| `Foundation` | All modules | macOS 14+ stable. |
| `ScreenCaptureKit` | `Capture/SCKitSystemAudioSource.swift` | Requires macOS 13+; we target 14+. The audio-only configuration is community-validated (research §5). |
| `AVFoundation` | `Capture/AVMicrophoneSource.swift`, `Encoding/*Recorder.swift`, `Permissions/MicrophonePermission.swift` | macOS 14+ stable. |
| `CoreAudio` | `Devices/AudioDeviceEnumerator.swift` | HAL APIs are stable. |
| `CoreMedia` | Capture, Aligning, Mixing, Encoding | Stable; `CMSampleBuffer` retain semantics noted in code comments. |
| `CoreGraphics` | `Permissions/ScreenRecordingPermission.swift` | `CGPreflight/RequestScreenCaptureAccess` are stable since macOS 11. |
| `Accelerate` | `Mixing/BufferSummer.swift`, `Encoding/WAVRecorder.swift` | `vDSP_*` is part of the OS ABI. |
| `AppKit` | `Capture/SCKit*`, `AVMicrophoneSource.swift` | `NSWorkspace.willSleep/didWake` notifications. |
| `Darwin` | `Daemon/Daemonizer.swift`, `Daemon/PidFile.swift` | POSIX syscalls. `fork()` accessed via `@_silgen_name` shim due to Apple's unavailability annotation; documented inline. |
| `Logging` | All modules using `LoggerFactory.make(_:)` | `swift-log` façade. |
| `ArgumentParser` | All `Sources/macrec/Commands/*.swift` | `swift-argument-parser`. |
| `Testing` | All `Tests/MacrecCoreTests/*.swift` | Apple's Swift Testing framework. Per Issue R-17, the local CommandLineTools toolchain has a stub runner; tests build cleanly but run only under Xcode / CI. |

## Manual-review items

None. The dependency surface is minimal (2 packages) and both are
first-party Apple libraries.

## Verdict

**Clean.** Phase 8 → READY for Phase 9.
