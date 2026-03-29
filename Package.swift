// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowPin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowPin",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-framework", "AppKit"]),
                .unsafeFlags(["-framework", "ApplicationServices"]),
                .unsafeFlags(["-framework", "ScreenCaptureKit"]),
            ]
        )
    ]
)
