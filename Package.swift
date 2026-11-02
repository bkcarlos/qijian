// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HomeKitReadOnly",
    platforms: [.macOS(.v13)],
    products: [.library(name: "HomeKitReadOnlyCore", targets: ["HomeKitReadOnlyCore"])],
    targets: [
        .target(name: "HomeKitReadOnlyCore"),
        .testTarget(name: "HomeKitReadOnlyCoreTests", dependencies: ["HomeKitReadOnlyCore"])
    ]
)
