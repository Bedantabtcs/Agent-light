// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentLightProtocol", targets: ["AgentLightProtocol"]),
        .library(name: "AgentLightCore", targets: ["AgentLightCore"]),
        .library(name: "AgentLightUI", targets: ["AgentLightUI"]),
        .executable(name: "AgentLight", targets: ["AgentLightApp"]),
        .executable(name: "AgentLightRelay", targets: ["AgentLightRelay"])
    ],
    targets: [
        .target(name: "AgentLightProtocol"),
        .target(name: "AgentLightCore", dependencies: ["AgentLightProtocol"]),
        .target(name: "AgentLightUI", dependencies: ["AgentLightCore"]),
        .executableTarget(name: "AgentLightApp", dependencies: ["AgentLightCore", "AgentLightUI"]),
        .executableTarget(
            name: "AgentLightRelay",
            dependencies: ["AgentLightCore", "AgentLightProtocol"]
        ),
        .testTarget(name: "AgentLightProtocolTests", dependencies: ["AgentLightProtocol"]),
        .testTarget(
            name: "AgentLightCoreTests",
            dependencies: ["AgentLightCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentLightUITests",
            dependencies: ["AgentLightUI", "AgentLightCore", "AgentLightProtocol"]
        )
    ],
    swiftLanguageModes: [.v6]
)
