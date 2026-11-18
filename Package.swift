// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoteSleuth",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "NoteSleuth",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NoteSleuth",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "NoteSleuthTests", dependencies: ["NoteSleuth"], path: "Tests/NoteSleuthTests"),
    ]
)
