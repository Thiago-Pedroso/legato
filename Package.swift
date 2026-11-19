// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Legato",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3")
    ],
    targets: [
        .target(name: "LegatoCore"),
        .executableTarget(
            name: "Legato",
            dependencies: ["LegatoCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(name: "LegatoCoreTests", dependencies: ["LegatoCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
