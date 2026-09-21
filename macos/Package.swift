// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenPoly",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "OpenPolyCore", path: "Sources/OpenPolyCore"),
        .executableTarget(
            name: "OpenPoly",
            dependencies: ["OpenPolyCore"],
            path: "Sources/OpenPoly"
        ),
        .executableTarget(
            name: "OpenPolyCheck",
            dependencies: ["OpenPolyCore"],
            path: "Sources/OpenPolyCheck"
        ),
    ]
)
