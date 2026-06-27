// swift-tools-version: 6.2
import PackageDescription

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
        .library(name: "DatabaseClientWasm", targets: ["DatabaseClientWasm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/database-kit.git", from: "26.0613.0"),
    ],
    targets: [
        .target(
            name: "DatabaseClient",
            dependencies: [
                .product(name: "Core", package: "database-kit"),
                .product(name: "QueryIR", package: "database-kit"),
                .product(name: "DatabaseClientProtocol", package: "database-kit"),
                .product(name: "Vector", package: "database-kit"),
                .product(name: "FullText", package: "database-kit"),
                .product(name: "Permuted", package: "database-kit"),
            ]
        ),
        .target(
            name: "DatabaseClientWasm",
            dependencies: [
                .product(name: "DatabaseKitWasmCore", package: "database-kit"),
            ]
        ),
        .testTarget(
            name: "DatabaseClientTests",
            dependencies: ["DatabaseClient"]
        ),
        .testTarget(
            name: "DatabaseClientWasmTests",
            dependencies: ["DatabaseClientWasm"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
