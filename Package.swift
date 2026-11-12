// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Asar",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "Asar", targets: ["Asar"])
    ],
    targets: [
        .target(name: "Asar", path: "Sources/Asar"),
        .executableTarget(name: "verify", dependencies: ["Asar"], path: "Examples/Verify"),
        .testTarget(name: "AsarTests", dependencies: ["Asar"], path: "Tests/AsarTests")
    ]
)
