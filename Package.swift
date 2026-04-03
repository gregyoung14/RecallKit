// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "RecallKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "RecallKit",
            targets: ["RecallKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Jaesung-Jung/SwiftXXHash.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "RecallKit",
            dependencies: [
                .product(name: "XXHash", package: "SwiftXXHash")
            ],
            path: "Sources/RecallKit",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "RecallKitTests",
            dependencies: ["RecallKit"],
            path: "Tests/RecallKitTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
