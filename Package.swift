// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Thock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Thock", targets: ["Thock"]),
        .library(name: "ThockCore", targets: ["ThockCore"]),
    ],
    targets: [
        .target(name: "ThockCore"),
        .executableTarget(name: "Thock", dependencies: ["ThockCore"]),
        .testTarget(name: "ThockCoreTests", dependencies: ["ThockCore"]),
    ]
)
