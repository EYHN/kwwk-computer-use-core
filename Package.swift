// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "kwwk-computer-use-core",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "KWWKComputerUseCore", targets: ["KWWKComputerUseCore"]),
    ],
    targets: [
        .target(
            name: "KWWKComputerUseCore",
            path: "Sources/KWWKComputerUseCore",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "KWWKComputerUseCoreTests",
            dependencies: ["KWWKComputerUseCore"],
            path: "Tests/KWWKComputerUseCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
