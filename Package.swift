// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeakUp",
    // FluidAudio 0.18 needs macOS 14 / iOS 17.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SpeakUpCore", targets: ["SpeakUpCore"]),
        .executable(name: "speakup", targets: ["speakup"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4"),
    ],
    targets: [
        .target(
            name: "SpeakUpCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "speakup", dependencies: ["SpeakUpCore"]),
        .testTarget(name: "SpeakUpCoreTests", dependencies: ["SpeakUpCore"]),
    ]
)
