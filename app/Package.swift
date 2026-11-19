// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotRecallApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotRecallApp", targets: ["NotRecallApp"])
    ],
    targets: [
        .executableTarget(
            name: "NotRecallApp",
            path: "Sources/NotRecallApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
