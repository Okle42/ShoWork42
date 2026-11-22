// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShoWork42",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "showork", targets: ["showork"]),
        .executable(name: "ShoWorkAgent", targets: ["ShoWorkAgent"]),
        .executable(name: "ShoWorkLauncher", targets: ["ShoWorkLauncher"]),
        // 11-23：Orbit42（新 App）共用看板／session 狀態／額度／自檢的核心
        .library(name: "ShoWorkCore", targets: ["ShoWorkCore"]),
    ],
    targets: [
        .target(name: "ShoWorkCore"),
        .executableTarget(name: "showork", dependencies: ["ShoWorkCore"]),
        .executableTarget(name: "ShoWorkAgent", dependencies: ["ShoWorkCore"]),
        .executableTarget(name: "ShoWorkLauncher", dependencies: ["ShoWorkCore"]),
        .testTarget(name: "ShoWorkCoreTests", dependencies: ["ShoWorkCore"]),
    ]
)
