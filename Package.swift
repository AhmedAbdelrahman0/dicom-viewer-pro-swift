// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DicomViewerPro",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "DicomViewerPro", targets: ["DicomViewerPro"]),
        .executable(name: "DicomViewerProApp", targets: ["DicomViewerProApp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DicomViewerPro",
            dependencies: [],
            path: "Sources/DicomViewerPro"
        ),
        .executableTarget(
            name: "DicomViewerProApp",
            dependencies: ["DicomViewerPro"],
            path: "Sources/DicomViewerProApp"
        ),
    ]
)
