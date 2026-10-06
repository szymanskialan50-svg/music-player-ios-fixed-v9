// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "YouTubePlayer",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "YouTubePlayer",
            targets: ["YouTubePlayer"]
        )
    ],
    targets: [
        .target(
            name: "YouTubePlayer",
            resources: [
                .process("Assets")
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
