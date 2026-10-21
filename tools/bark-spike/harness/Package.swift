// swift-tools-version:5.10
import PackageDescription

// Same FluidAudio Whale pins, so timings and output match the app's Parakeet path.
let package = Package(
    name: "asr-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1"),
    ],
    targets: [
        .executableTarget(
            name: "asr-bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
