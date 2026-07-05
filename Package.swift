// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentLightProtocol", targets: ["AgentLightProtocol"]),
        .library(name: "AgentLightCore", targets: ["AgentLightCore"]),
        .executable(name: "AgentLight", targets: ["AgentLightApp"]),
        .executable(name: "AgentLightRelay", targets: ["AgentLightRelay"])
    ],
    targets: [
        .target(name: "AgentLightProtocol"),
        .target(name: "AgentLightCore", dependencies: ["AgentLightProtocol"]),
        .executableTarget(name: "AgentLightApp"),
        .executableTarget(
            name: "AgentLightRelay",
            dependencies: ["AgentLightCore", "AgentLightProtocol"]
        ),
        .testTarget(name: "AgentLightProtocolTests", dependencies: ["AgentLightProtocol"]),
        .testTarget(name: "AgentLightCoreTests", dependencies: ["AgentLightCore"])
    ],
    swiftLanguageModes: [.v6]
)
