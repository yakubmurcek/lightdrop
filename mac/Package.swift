// swift-tools-version:5.10
// LightDrop: drag a file to the notch and it goes to the other person (lightdrop).
import PackageDescription

let package = Package(
    name: "LightDrop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LightDrop", path: "Sources/LightDrop"),
        .testTarget(name: "LightDropTests", dependencies: ["LightDrop"], path: "Tests/LightDropTests"),
    ]
)
