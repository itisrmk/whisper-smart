// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperSmart",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whisper Smart", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: ["Sparkle"],
            path: "app",
            exclude: [],
            sources: ["App", "Core", "UI"]
        )
    ]
)
