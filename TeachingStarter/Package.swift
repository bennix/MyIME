// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeachingStarter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TeachingCore", targets: ["TeachingCore"])
    ],
    targets: [
        .target(name: "TeachingCore"),
        .testTarget(name: "TeachingCoreTests", dependencies: ["TeachingCore"])
    ]
)
