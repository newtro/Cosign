// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CosignVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CosignVoice", targets: ["CosignVoice"]),
    ],
    dependencies: [
        .package(path: "../CosignCore"),
    ],
    targets: [
        .target(
            name: "CosignVoice",
            dependencies: ["CosignCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CosignVoiceTests",
            dependencies: ["CosignVoice", "CosignCore"]
        ),
    ]
)
