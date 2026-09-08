// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightSnap",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightSnap", targets: ["LightSnap"])],
    targets: [
        .target(name: "CaptureCore"),
        .executableTarget(name: "LightSnap", dependencies: ["CaptureCore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"])
    ],
    swiftLanguageModes: [.v5]
)
