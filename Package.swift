// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShoWork42",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "showork", targets: ["showork"]),
        .executable(name: "ShoWorkAgent", targets: ["ShoWorkAgent"]),
    ],
    targets: [
        .target(name: "ShoWorkCore"),
        .executableTarget(name: "showork", dependencies: ["ShoWorkCore"]),
        .executableTarget(name: "ShoWorkAgent", dependencies: ["ShoWorkCore"]),
        .testTarget(name: "ShoWorkCoreTests", dependencies: ["ShoWorkCore"]),
    ]
)
