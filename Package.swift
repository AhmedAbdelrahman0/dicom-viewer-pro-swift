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
    dependencies: [],
    targets: [
        .target(
            name: "Tracer",
            dependencies: [],
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
