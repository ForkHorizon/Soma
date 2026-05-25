// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Moodling",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Moodling", path: "Moodling"),
        .testTarget(name: "MoodlingTests", dependencies: ["Moodling"])
    ]
)
