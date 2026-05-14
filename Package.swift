// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MojoPulse",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MojoPulse",
            path: "Sources/MojoPulse",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
