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
        .library(
            name: "DatabaseClientJavaScript",
            targets: ["DatabaseClientJavaScript"]
        ),
        .library(name: "DatabaseClientHTTP", targets: ["DatabaseClientHTTP"]),
        .library(name: "DatabaseClientWebSocket", targets: ["DatabaseClientWebSocket"]),
        .library(
            name: "DatabaseClientFramedStream",
            targets: ["DatabaseClientFramedStream"]
        ),
    ],
    traits: [
        .trait(name: "MultiBase"),
    ],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/database-kit.git",
            revision: "b325109676a4b9b3431e2e306ca8c0dcf1d9a7bf",
            traits: [
                .trait(
                    name: "MultiBase",
                    condition: .when(traits: ["MultiBase"])
                ),
            ]
        ),
        .package(
            url: "https://github.com/1amageek/database-types.git",
            from: "26.1021.0"
        ),
        .package(
            url: "https://github.com/1amageek/JavaScriptKit.git",
            from: "0.57.2"
        ),
    ],
    targets: [
        .target(
            name: "DatabaseClient",
            dependencies: [
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/DatabaseClient",
            exclude: ["DESIGN.md", "QueryExecution/DESIGN.md"],
            swiftSettings: [
                .define(
                    "DATABASE_CLIENT_MULTI_BASE",
                    .when(traits: ["MultiBase"])
                ),
            ]
        ),
        .target(
            name: "DatabaseClientJavaScript",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ],
            path: "Sources/JavaScriptClient"
        ),
        .target(
            name: "DatabaseClientWebSocket",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/WebSocketClient",
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "DatabaseClientHTTP",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/HTTPClient",
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "DatabaseClientFramedStream",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/FramedStreamClient"
        ),
        .testTarget(
            name: "DatabaseClientTests",
            dependencies: [
                "DatabaseClient",
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .target(
                    name: "DatabaseClientJavaScript",
                    condition: .when(platforms: [.wasi])
                ),
                .target(name: "DatabaseClientHTTP", condition: .when(platforms: hostPlatforms)),
                .target(name: "DatabaseClientWebSocket", condition: .when(platforms: hostPlatforms)),
                "DatabaseClientFramedStream",
                .product(
                    name: "JavaScriptEventLoop",
                    package: "JavaScriptKit",
                    condition: .when(platforms: [.wasi])
                ),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_CLIENT_MULTI_BASE",
                    .when(traits: ["MultiBase"])
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
