// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeakUp",
    // FluidAudio 0.18 needs macOS 14 / iOS 17.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SpeakUpCore", targets: ["SpeakUpCore"]),
        .library(name: "SpeakUpMLX", targets: ["SpeakUpMLX"]),
        .executable(name: "speakup", targets: ["speakup"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.33.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SpeakUpCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        // The MLX coach is its own target, so SpeakUpCore stays free of MLX and its Metal shaders.
        .target(
            name: "SpeakUpMLX",
            dependencies: [
                "SpeakUpCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(name: "speakup", dependencies: ["SpeakUpCore", "SpeakUpMLX"]),
        .testTarget(name: "SpeakUpCoreTests", dependencies: ["SpeakUpCore"]),
    ]
)
