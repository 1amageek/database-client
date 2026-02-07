// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "database-client",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "DatabaseClient", targets: ["DatabaseClient"]),
    ],
    dependencies: [
        .package(path: "../database-kit"),
    ],
    targets: [
        .target(
            name: "DatabaseClient",
            dependencies: [
                .product(name: "Core", package: "database-kit"),
                .product(name: "QueryIR", package: "database-kit"),
                .product(name: "DatabaseClientProtocol", package: "database-kit"),
            ]
        ),
        .testTarget(
            name: "DatabaseClientTests",
            dependencies: ["DatabaseClient"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
