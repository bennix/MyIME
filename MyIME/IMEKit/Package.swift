// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IMEKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "IMEKit", targets: ["IMEKit"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "IMEKit",
            dependencies: ["CSQLite"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "IMEKitTests", dependencies: ["IMEKit"]),
    ]
)
