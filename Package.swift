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
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "KWWKComputerUseCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/KWWKComputerUseCore"
        ),
        .testTarget(
            name: "KWWKComputerUseCoreTests",
            dependencies: ["KWWKComputerUseCore"],
            path: "Tests/KWWKComputerUseCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
