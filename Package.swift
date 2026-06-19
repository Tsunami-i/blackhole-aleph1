// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlackHoleScreenWarp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BlackHoleScreenWarp",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
