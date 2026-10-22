// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentGlance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentglance", targets: ["agentglance"]),
        .executable(name: "AgentGlanceApp", targets: ["AgentGlanceApp"]),
    ],
    targets: [
        .target(name: "AgentGlanceCore"),
        .executableTarget(name: "agentglance", dependencies: ["AgentGlanceCore"]),
        .executableTarget(name: "AgentGlanceApp", dependencies: ["AgentGlanceCore"]),
        .testTarget(name: "AgentGlanceCoreTests", dependencies: ["AgentGlanceCore"]),
    ],
    swiftLanguageModes: [.v5]
)
