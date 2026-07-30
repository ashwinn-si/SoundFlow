// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundFlow",
    platforms: [
        // macOS 15 for Synchronization / modern SwiftUI scene APIs.
        // Process taps themselves need 14.4+.
        .macOS(.v15)
    ],
    products: [
        // Headless engine smoke test — verifies per-app volume without any UI.
        .executable(name: "SoundFlowSpike", targets: ["SoundFlowSpike"]),
        // The app.
        .executable(name: "SoundFlowApp", targets: ["SoundFlowApp"])
    ],
    targets: [
        // ── Shared Core Engine ──────────────────────────────────────────
        // Process registry, taps, aggregate routes, mixing IOProc, watchdog.
        .target(
            name: "SoundFlowCore",
            path: "Sources/SoundFlowCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit")
            ]
        ),

        // ── Engine smoke test CLI ───────────────────────────────────────
        .executableTarget(
            name: "SoundFlowSpike",
            dependencies: ["SoundFlowCore"],
            path: "Sources/SoundFlowSpikeMain",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit")
            ]
        ),

        // ── SwiftUI App ─────────────────────────────────────────────────
        .executableTarget(
            name: "SoundFlowApp",
            dependencies: ["SoundFlowCore"],
            path: "Sources/SoundFlowApp",
            exclude: [
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources/AppIcon.icns")
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                // SMAppService, for the launch-at-login toggle.
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
