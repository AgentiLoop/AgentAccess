// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentAccess",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentAccess", targets: ["AgentAccess"]),
    ],
    dependencies: [
        .package(url: "https://github.com/macOS26/AgentAudit.git", from: "1.3.1"),
        .package(url: "https://github.com/steipete/AXorcist.git", from: "0.1.6"),
    ],
    targets: [
        .target(name: "AgentAccess", dependencies: ["AgentAudit", "AXorcist"]),
    ]
)
