// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minutes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Minutes", targets: ["Minutes"])
    ],
    targets: [
        .executableTarget(
            name: "Minutes",
            path: "Minutes",
            exclude: [
                "Resources/Info.plist"
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        )
    ]
)
