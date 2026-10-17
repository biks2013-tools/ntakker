// swift-tools-version:6.2
// ntakker-cli — see docs/design/plan-001-recording-tool.md §A
// swift-tools-version bumped 5.9 → 6.2 (plan-005 Phase 0 / Task 0.1) so
// that `.macOS(.v26)` is available in PackageDescription. See CLAUDE.md
// "Approved Exception 002" for the deployment-target bump rationale.
import PackageDescription

let package = Package(
    name: "ntakker-cli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ntakker-cli", targets: ["ntakker-cli"]),
        .library(name: "NtakkerCore", targets: ["NtakkerCore"]),
        .executable(name: "ntakker", targets: ["ntakker"]),
        .executable(name: "ntakker-studio", targets: ["ntakker-studio"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/apple/swift-log",
            from: "1.5.4"
        ),
        // Argmax's open-source Swift bundle. Exposes the `WhisperKit`
        // product — Whisper (large-v3 multilingual by default) running
        // on-device via CoreML / Apple Neural Engine. Used by the new
        // `WhisperKitTranscriptionProvider` (id `whisperkit`) to give
        // users an on-device alternative to Apple Speech for locales
        // whose Apple-shipped asset is not downloadable (e.g. el-GR
        // — confirmed unavailable on the user's Mac, 2026-04-29).
        // Pinned to `0.18.0` to match the version used by the sibling
        // `notch` project, which has been running this in production.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "0.18.0"
        ),
        // FluidAudio — Swift-native CoreML wrapper around NVIDIA's
        // Parakeet TDT V3 multilingual ASR (~25 European languages
        // including Greek). Pinned to v0.8.2 for plan-012 Phase B.
        //
        // Why v0.8.2 (not the latest v0.9.x): v0.9.0+ bumped its
        // own swift-tools-version to 6.0 and the new
        // `StreamingAsrManager.swift` triggers Swift 6 strict-
        // concurrency `SendingRisksDataRace` errors when the package
        // is built. v0.8.x uses tools 5.10 — clean build under our
        // existing config — and exposes the same ASR surface
        // (AsrManager / AsrModels.downloadAndLoad(version: .v3)) we
        // need for batch transcription. We're batch-only by design
        // (mirrors WhisperKit's posture), so the absence of the
        // streaming manager is irrelevant. Bump pin once upstream
        // resolves the strict-concurrency issue.
        //
        // Library product `FluidAudio` exposes ASR + diarization +
        // VAD; we only consume the ASR surface. `FluidAudioTTS`
        // (separate product, GPL-3.0 ESpeakNG) is intentionally
        // NOT pulled in.
        .package(
            url: "https://github.com/FluidInference/FluidAudio",
            exact: "0.8.2"
        ),
    ],
    targets: [
        .executableTarget(
            name: "ntakker-cli",
            dependencies: [
                "NtakkerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ntakker-cli",
            linkerSettings: [
                // Embed Resources/Info.plist into the binary's __TEXT,__info_plist
                // section so macOS reads NSMicrophoneUsageDescription and
                // NSScreenCaptureUsageDescription. Without this, TCC prompts
                // never appear for SPM-built CLI tools.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .target(
            name: "NtakkerCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                // plan-012 Phase B — Parakeet TDT V3 multilingual ASR.
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/NtakkerCore"
        ),
        .testTarget(
            name: "NtakkerCoreTests",
            dependencies: ["NtakkerCore"],
            path: "Tests/NtakkerCoreTests",
            swiftSettings: [
                // Without full Xcode, Swift Testing's framework lives in
                // /Library/Developer/CommandLineTools/Library/Developer/Frameworks/.
                // SwiftPM only adds it to the include path (-I), but the
                // module sits inside Testing.framework, so we also need
                // a framework search path (-F).
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        ),
        // -- ntakker (Phase B; plan-002 §15.9) --
        // Pure-logic UI components live here so NtakkerUITests can import
        // them without pulling in the AppKit shell. Sibling to
        // Sources/ntakker/ (NOT nested) per SPM target-path rules.
        .target(
            name: "NtakkerUIKit",
            dependencies: [
                "NtakkerCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/NtakkerUIKit"
        ),
        // The menu-bar accessory app. Depends on NtakkerUIKit for the
        // domain layer (RecordingController, SessionCoordinator,
        // FilenameGenerator, …) and embeds Resources/Ntakker-Info.plist
        // — a SEPARATE plist from the CLI so TCC bundle ids do not
        // collide (R-23 — com.giorgosmarinos.ntakker ≠ com.giorgosmarinos.ntakker-cli).
        .executableTarget(
            name: "ntakker",
            dependencies: [
                "NtakkerCore",
                "NtakkerUIKit",
                "NtakkerSettingsUI",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ntakker",
            linkerSettings: [
                // Embed Resources/Ntakker-Info.plist into the binary's
                // __TEXT,__info_plist section. Same mechanism as the
                // CLI target, just pointing at the UI's own plist
                // (LSUIElement=true, com.giorgosmarinos.ntakker).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Ntakker-Info.plist",
                ])
            ]
        ),
        // Tests target the LIBRARY (NtakkerUIKit), not the executable —
        // SPM/Apple convention. Mirrors NtakkerCoreTests' Swift Testing
        // framework discovery workaround for CommandLineTools (R-17).
        .testTarget(
            name: "NtakkerUITests",
            dependencies: ["NtakkerUIKit"],
            path: "Tests/NtakkerUITests",
            swiftSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        ),
        // -- Shared settings UI (plan-025) --
        // The settings panes and the live store over the shared
        // ~/.tool-agents/ntakker/.env, embedded by ntakker's and
        // ntakker studio's Settings windows.
        .target(
            name: "NtakkerSettingsUI",
            dependencies: [
                "NtakkerCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/NtakkerSettingsUI"
        ),
        // -- ntakker-studio (plan-024) --
        // Testable logic for the recordings explorer: library scan,
        // timing, cut + retime, Ask prompts, search, re-transcribe.
        .target(
            name: "NtakkerStudioKit",
            dependencies: [
                "NtakkerCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/NtakkerStudioKit"
        ),
        // The Dock app. Own plist and bundle id (com.giorgosmarinos.ntakker-studio).
        .executableTarget(
            name: "ntakker-studio",
            dependencies: [
                "NtakkerCore",
                "NtakkerStudioKit",
                "NtakkerSettingsUI",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ntakker-studio",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/NtakkerStudio-Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "NtakkerStudioTests",
            dependencies: ["NtakkerStudioKit", "NtakkerCore"],
            path: "Tests/NtakkerStudioTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        ),
    ],
    // Tools-version 6.2 defaults to Swift 6 language mode + strict
    // concurrency, which would turn many existing warnings (in code we
    // are NOT touching in plan-005 Phase 0) into errors. Pin the
    // language mode to Swift 5 for now; per-target migration to Swift 6
    // is tracked separately and is out of scope for the deployment-
    // target bump (plan-005 Phase 0 / Task 0.1).
    swiftLanguageModes: [.v5]
)
