// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MITSchemeApp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MITSchemeCore", targets: ["MITSchemeCore"]),
        .executable(name: "MITSchemeApp", targets: ["MITSchemeApp"]),
    ],
    targets: [
        .target(
            name: "CPTYSpawn",
            path: "Sources/CPTYSpawn"
        ),
        .target(
            name: "MITSchemeCore",
            dependencies: ["CPTYSpawn"],
            path: "Sources/MITSchemeCore"
        ),
        .executableTarget(
            name: "MITSchemeApp",
            dependencies: ["MITSchemeCore"],
            path: "Sources/MITSchemeApp"
        ),
        .testTarget(
            name: "MITSchemeAppTests",
            dependencies: ["MITSchemeCore"],
            path: "Tests/MITSchemeAppTests"
        ),
    ]
)
