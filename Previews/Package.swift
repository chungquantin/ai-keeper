// swift-tools-version:5.9
// The component catalog: open this folder's Package.swift in Xcode (`open Previews/Package.swift`) and use the canvas.
// It is a separate package because `#Preview` needs Xcode's macro plugin, and the main package must still build
// with only the command-line tools (and in the release build, which has no previews).
import PackageDescription

let package = Package(
    name: "AIKeeperPreviews",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "AIKeeper", path: "..")],
    targets: [
        .target(name: "AIKeeperPreviews", dependencies: [.product(name: "AIKeeperKit", package: "AIKeeper")], path: "Sources/AIKeeperPreviews"),
    ]
)
