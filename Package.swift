// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioToAudioPlannerKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AudioToAudioPlanner", targets: ["AudioToAudioPlanner"])
    ],
    targets: [
        .target(
            name: "AudioToAudioPlanner",
            path: "AudioToAudio/AudioToAudioPlanner"
        ),
        .testTarget(
            name: "AudioToAudioPlannerTests",
            dependencies: ["AudioToAudioPlanner"],
            path: "AudioToAudioPlannerTests"
        )
    ]
)
