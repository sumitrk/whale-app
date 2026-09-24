// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextProcessing",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TextProcessing", targets: ["TextProcessing"])
    ],
    dependencies: [
        // Must match the version the Whale project pins.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1")
    ],
    targets: [
        // The prebuilt NeMo text-processing engine (`CNemoTextProcessing`) comes
        // from FluidAudio, which bundles the text-processing-rs xcframework from
        // 0.15.6 onward. We call its C API directly rather than FluidAudio's
        // `TextNormalizer` so we keep control of the options (`keepBareSecond`)
        // and the hyphenated-number retry below.
        .target(
            name: "TextProcessing",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
