// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIKeeper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIKeeper", targets: ["AIKeeper"]),
        .library(name: "AIKeeperKit", targets: ["AIKeeperKit"]),
    ],
    targets: [
        // Everything: the scanner, the cleanup engine, the keeper command, the SwiftUI views and their previews.
        .target(name: "AIKeeperKit", path: "Sources/AIKeeperKit"),
        // A one-line launcher, so the binary is still called AIKeeper.
        .executableTarget(name: "AIKeeper", dependencies: ["AIKeeperKit"], path: "Sources/AIKeeper"),
    ]
)
