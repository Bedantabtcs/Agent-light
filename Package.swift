// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentLightProtocol", targets: ["AgentLightProtocol"]),
        .executable(name: "AgentLight", targets: ["AgentLightApp"]),
        .executable(name: "AgentLightRelay", targets: ["AgentLightRelay"])
    ],
    targets: [
        .target(name: "AgentLightProtocol"),
        .executableTarget(name: "AgentLightApp"),
        .executableTarget(name: "AgentLightRelay", dependencies: ["AgentLightProtocol"]),
        .testTarget(name: "AgentLightProtocolTests", dependencies: ["AgentLightProtocol"])
    ],
    swiftLanguageModes: [.v6]
)
