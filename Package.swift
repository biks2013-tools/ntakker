// swift-tools-version:6.2
// macrec — see docs/design/plan-001-recording-tool.md §A
// swift-tools-version bumped 5.9 → 6.2 (plan-005 Phase 0 / Task 0.1) so
// that `.macOS(.v26)` is available in PackageDescription. See CLAUDE.md
// "Approved Exception 002" for the deployment-target bump rationale.
import PackageDescription

let package = Package(
    name: "macrec",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "macrec", targets: ["macrec"]),
        .library(name: "MacrecCore", targets: ["MacrecCore"]),
        .executable(name: "macrec-ui", targets: ["macrec-ui"]),
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
    ],
    targets: [
        .executableTarget(
            name: "macrec",
            dependencies: [
                "MacrecCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/macrec",
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
            name: "MacrecCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/MacrecCore"
        ),
        .testTarget(
            name: "MacrecCoreTests",
            dependencies: ["MacrecCore"],
            path: "Tests/MacrecCoreTests",
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
        // -- macrec-ui (Phase B; plan-002 §15.9) --
        // Pure-logic UI components live here so MacrecUITests can import
        // them without pulling in the AppKit shell. Sibling to
        // Sources/macrec-ui/ (NOT nested) per SPM target-path rules.
        .target(
            name: "MacrecUIKit",
            dependencies: [
                "MacrecCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/MacrecUIKit"
        ),
        // The menu-bar accessory app. Depends on MacrecUIKit for the
        // domain layer (RecordingController, SessionCoordinator,
        // FilenameGenerator, …) and embeds Resources/MacrecUI-Info.plist
        // — a SEPARATE plist from the CLI so TCC bundle ids do not
        // collide (R-23 — com.local.macrec-ui ≠ com.local.macrec).
        .executableTarget(
            name: "macrec-ui",
            dependencies: [
                "MacrecCore",
                "MacrecUIKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/macrec-ui",
            linkerSettings: [
                // Embed Resources/MacrecUI-Info.plist into the binary's
                // __TEXT,__info_plist section. Same mechanism as the
                // CLI target, just pointing at the UI's own plist
                // (LSUIElement=true, com.local.macrec-ui).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/MacrecUI-Info.plist",
                ])
            ]
        ),
        // Tests target the LIBRARY (MacrecUIKit), not the executable —
        // SPM/Apple convention. Mirrors MacrecCoreTests' Swift Testing
        // framework discovery workaround for CommandLineTools (R-17).
        .testTarget(
            name: "MacrecUITests",
            dependencies: ["MacrecUIKit"],
            path: "Tests/MacrecUITests",
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
