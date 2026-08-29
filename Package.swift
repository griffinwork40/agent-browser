// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentBrowser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentBrowser",
            path: "Sources/AgentBrowser",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AgentBrowserTests",
            dependencies: ["AgentBrowser"]
        )
    ]
)
