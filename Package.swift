// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentBrowser",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentBrowser",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/AgentBrowser",
            resources: [
                .process("Resources"),
                .copy("WebKit/UserScripts")
            ]
        ),
        .executableTarget(
            name: "agent-browser-mcp",
            path: "Sources/AgentBrowserMCP"
        ),
        .testTarget(
            name: "AgentBrowserTests",
            dependencies: [
                "AgentBrowser",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "AgentBrowserMCPTests",
            dependencies: ["agent-browser-mcp"]
        )
    ]
)
