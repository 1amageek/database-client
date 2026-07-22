// swift-tools-version: 6.4
import PackageDescription

let hostPlatforms: [Platform] = [
    .macOS,
    .iOS,
    .tvOS,
    .watchOS,
    .visionOS,
    .linux,
]

let package = Package(
    name: "database-client",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "DatabaseClient", targets: ["DatabaseClient"]),
        .library(name: "DatabaseClientWorker", targets: ["DatabaseClientWorker"]),
        .library(name: "DatabaseClientHTTP", targets: ["DatabaseClientHTTP"]),
        .library(name: "DatabaseClientWebSocket", targets: ["DatabaseClientWebSocket"]),
    ],
    dependencies: [
        .package(path: "../database-kit"),
        .package(url: "https://github.com/1amageek/JavaScriptKit.git", from: "0.57.0"),
    ],
    targets: [
        .target(
            name: "DatabaseClient",
            dependencies: [
                .product(name: "DatabaseValue", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/DatabaseClient"
        ),
        .target(
            name: "DatabaseClientWorker",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseValue", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ],
            path: "Sources/WorkerClient"
        ),
        .target(
            name: "DatabaseClientWebSocket",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseValue", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/WebSocketClient"
        ),
        .target(
            name: "DatabaseClientHTTP",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseValue", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/HTTPClient"
        ),
        .testTarget(
            name: "DatabaseClientTests",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseValue", package: "database-kit"),
                .target(name: "DatabaseClientHTTP", condition: .when(platforms: hostPlatforms)),
                .target(name: "DatabaseClientWebSocket", condition: .when(platforms: hostPlatforms)),
                .product(name: "DatabaseWire", package: "database-kit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
