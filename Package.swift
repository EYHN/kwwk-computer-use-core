// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "mac-computer-use",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MacComputerUse", targets: ["MacComputerUse"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "MacComputerUse",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/MacComputerUse"
        ),
        .testTarget(
            name: "MacComputerUseTests",
            dependencies: ["MacComputerUse"],
            path: "Tests/MacComputerUseTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
