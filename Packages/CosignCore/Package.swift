// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CosignCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CosignCore", targets: ["CosignCore"]),
    ],
    targets: [
        .target(name: "CosignCore"),
        .testTarget(name: "CosignCoreTests", dependencies: ["CosignCore"]),
    ]
)
