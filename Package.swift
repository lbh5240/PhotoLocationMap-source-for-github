// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZORACamera",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [.library(name: "ZoraCore", targets: ["ZoraCore"])],
    targets: [
        .target(name: "ZoraCore"),
        .testTarget(name: "ZoraCoreTests", dependencies: ["ZoraCore"])
    ],
    swiftLanguageModes: [.v6]
)
