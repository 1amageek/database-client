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

let accessRuntimeLinkerSettings: [LinkerSetting]
if let archive = Context.environment["DATABASE_ACCESS_UNICODE_ARCHIVE"], !archive.isEmpty {
    accessRuntimeLinkerSettings = [.unsafeFlags(["-Xlinker", archive], .when(platforms: [.wasi]))]
} else {
    accessRuntimeLinkerSettings = []
}

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
        .library(name: "DatabaseAccess", targets: ["DatabaseAccess"]),
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
            revision: "678b70daee9ef9d72966f147d6e6bb4110a7da95",
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
            name: "DatabaseAccess",
            dependencies: [
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            exclude: ["DESIGN.md", "NamedAccess/DESIGN.md", "QueryReferences/DESIGN.md", "Results/DESIGN.md"],
            swiftSettings: [.define("DATABASE_CLIENT_MULTI_BASE", .when(traits: ["MultiBase"]))]
        ),
        .target(
            name: "DatabaseClient",
            dependencies: [
                "DatabaseAccess",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            path: "Sources/DatabaseClient",
            exclude: ["DESIGN.md", "QueryExecution/DESIGN.md", "Access/DESIGN.md"],
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
        .executableTarget(
            name: "DatabaseAccessRuntimeContract",
            dependencies: ["DatabaseAccess", "DatabaseClient", .product(name: "DatabaseTypes", package: "database-types"), .product(name: "DatabaseKit", package: "database-kit"), .product(name: "DatabaseWire", package: "database-kit")],
            path: "Tests/DatabaseAccessRuntimeContract",
            exclude: ["run.mjs"],
            swiftSettings: [.define("DATABASE_CLIENT_MULTI_BASE", .when(traits: ["MultiBase"]))],
            linkerSettings: accessRuntimeLinkerSettings
        ),
        .testTarget(
            name: "DatabaseClientTests",
            dependencies: [
                "DatabaseAccess",
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
