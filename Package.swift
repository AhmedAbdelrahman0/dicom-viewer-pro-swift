// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tracer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "Tracer", targets: ["Tracer"]),
        .executable(name: "TracerApp", targets: ["TracerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.6.4")),
        .package(url: "https://github.com/apple/swift-metrics.git", .upToNextMinor(from: "2.7.1")),
    ],
    targets: [
        .target(
            name: "Tracer",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            path: "Sources/Tracer"
        ),
        .executableTarget(
            name: "TracerApp",
            dependencies: ["Tracer"],
            path: "Sources/TracerApp",
            resources: [
                .copy("Resources/AppIcon.icns"),
            ]
        ),
        .testTarget(
            name: "TracerTests",
            dependencies: ["Tracer"],
            path: "Tests/TracerTests"
        ),
    ]
)
