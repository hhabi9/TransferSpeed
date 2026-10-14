// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TransferSpeed",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "TransferSpeed"),
        .testTarget(name: "TransferSpeedTests", dependencies: ["TransferSpeed"]),
    ]
)
