// swift-tools-version: 6.2
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
        .library(name: "WebSocketClient", targets: ["WebSocketClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/database-kit.git", from: "26.0628.0"),
    ],
    targets: [
        .target(
            name: "DatabaseClient",
            dependencies: [
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "Core", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "QueryIR", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "DatabaseClientProtocol", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "Vector", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "FullText", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "Permuted", package: "database-kit", condition: .when(platforms: hostPlatforms)),
            ]
        ),
        .target(
            name: "WebSocketClient",
            dependencies: [
                "DatabaseClient",
                .product(name: "Core", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "DatabaseClientProtocol", package: "database-kit", condition: .when(platforms: hostPlatforms)),
            ]
        ),
        .testTarget(
            name: "DatabaseClientTests",
            dependencies: [
                "DatabaseClient",
                .target(name: "WebSocketClient", condition: .when(platforms: hostPlatforms)),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "Core", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "QueryIR", package: "database-kit", condition: .when(platforms: hostPlatforms)),
                .product(name: "DatabaseClientProtocol", package: "database-kit", condition: .when(platforms: hostPlatforms)),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
