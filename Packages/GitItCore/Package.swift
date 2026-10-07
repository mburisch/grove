// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitItCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "GitItCore", targets: ["GitItCore"]),
    ],
    targets: [
        .target(name: "GitItCore"),
        .testTarget(name: "GitItCoreTests", dependencies: ["GitItCore"]),
    ]
)
