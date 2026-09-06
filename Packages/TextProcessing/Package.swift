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
    targets: [
        // Prebuilt NeMo text-processing engine (FST grammars, 7 languages) from
        // FluidInference/text-processing-rs, the same xcframework FluidAudio links
        // on main. Whale is pinned to FluidAudio 0.15.5, which still looks the
        // engine up at runtime and silently passes text through when it is absent,
        // so we link it ourselves. Once FluidAudio ships a release that bundles the
        // engine, this package can be dropped in favour of its `TextNormalizer`.
        .binaryTarget(
            name: "NemoTextProcessing",
            url:
                "https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.0/NemoTextProcessing.xcframework.zip",
            checksum: "76d0ee9a32b1ee2193231299180ca9bc4fc7e98794e771b3d55d66498352d85f"
        ),
        .target(
            name: "TextProcessing",
            dependencies: ["NemoTextProcessing"]
        ),
    ]
)
