// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowerFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PowerFlow", targets: ["PowerFlow"]),
        .executable(name: "powerflow-probe", targets: ["PowerFlowProbe"])
    ],
    targets: [
        .target(
            name: "PowerFlowCore",
            path: "Sources/PowerFlowCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "PowerFlow",
            dependencies: ["PowerFlowCore"],
            path: "Sources/PowerFlow",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "PowerFlowProbe",
            dependencies: ["PowerFlowCore"],
            path: "Sources/PowerFlowProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PowerFlowCoreTests",
            dependencies: ["PowerFlowCore"],
            path: "Tests/PowerFlowCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
