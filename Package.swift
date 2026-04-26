// swift-tools-version:5.9
// macrec — see docs/design/plan-001-recording-tool.md §A
import PackageDescription

let package = Package(
    name: "macrec",
    platforms: [.macOS(.v14)],
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
    ]
)
