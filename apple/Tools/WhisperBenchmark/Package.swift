// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperBenchmark",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperBenchmark",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ]
)
