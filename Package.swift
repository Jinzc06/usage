// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Usage",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Usage", targets: ["Usage"])
    ],
    targets: [
        .executableTarget(
            name: "Usage",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "UsageTests",
            dependencies: ["Usage"]
        ),
    ]
)
