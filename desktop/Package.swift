// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AGYAutoChanger",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AGYAutoChanger",
            targets: ["AGYAutoChanger"]
        ),
        .executable(
            name: "AGYWatcher",
            targets: ["AGYWatcher"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AGYAutoChanger",
            path: "Sources/AGYAutoChanger",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AGYWatcher",
            path: "Sources/AGYWatcher"
        ),
        .testTarget(
            name: "AGYAutoChangerTests",
            dependencies: ["AGYAutoChanger"],
            path: "Tests/AGYAutoChangerTests"
        )
    ]
)
