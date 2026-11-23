// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnySnap",
    platforms: [.macOS(.v14)],
    products: [
        // Menu bar app (wrapped into AnySnap.app by scripts/build-app.sh)
        .executable(name: "AnySnapBar", targets: ["AnySnapBar"]),
        // CLI + MCP server, used by agents (Claude Desktop, Claude Code, Codex, ...)
        .executable(name: "anysnap", targets: ["anysnap"]),
    ],
    targets: [
        .target(name: "AnySnapCore"),
        .executableTarget(name: "AnySnapBar", dependencies: ["AnySnapCore"]),
        .executableTarget(name: "anysnap", dependencies: ["AnySnapCore"]),
    ]
)
