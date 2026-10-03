// swift-tools-version:6.0
// Build the app bundle with Scripts/build.sh (`swift build` alone builds just the executable); test with Scripts/test.sh.
import PackageDescription

let package = Package(
    name: "EyesOnly",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "EyesOnly", path: "Sources/EyesOnly"),
        .testTarget(name: "EyesOnlyTests", dependencies: ["EyesOnly"]),
    ],
    swiftLanguageModes: [.v5]
)
