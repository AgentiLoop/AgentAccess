// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentAccess",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentAccess", targets: ["AgentAccess"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AgentiLoop/AgentAudit.git", from: "1.3.1"),
        // AXorcist v0.1.6+'s manifest switches to a local path dependency
        // (.package(path: "../Commander")) whenever a sibling Commander folder
        // exists — which is exactly Xcode's SourcePackages/checkouts layout.
        // That makes 0.1.6+ unresolvable from Xcode, so requiring from: 0.1.6
        // silently pinned consumers to AgentAccess 2.10.5. Keep the floor at
        // 0.1.0: CLI builds still resolve 0.1.6+, Xcode resolves 0.1.0.
        .package(url: "https://github.com/steipete/AXorcist.git", from: "0.1.0"),
    ],
    targets: [
        .target(name: "AgentAccess", dependencies: ["AgentAudit", "AXorcist"]),
    ]
)
