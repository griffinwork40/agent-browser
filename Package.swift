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
            dependencies: ["AgentBrowser"]
        ),
        .testTarget(
            name: "AgentBrowserMCPTests",
            dependencies: ["agent-browser-mcp"]
        )
    ]
)
