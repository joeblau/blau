// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            url: "https://github.com/joeblau/blau/releases/download/ghosttykit-1.3.1-blau.1/GhosttyKit.xcframework.zip",
            checksum: "a413d4d123835f6e83d5292de13cba15e544cfe0ffa7d70484345c174421cdfb"
        ),
    ]
)
