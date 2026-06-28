// swift-tools-version: 6.2
import PackageDescription

let wireClientEnabled = Context.environment["DATABASE_WIRE"] == "1"
    || Context.environment["DATABASE_CLIENT_WIRE"] == "1"

let hostSourceExcludes = [
    "AnnotatedQueryResult.swift",
    "ClientConfiguration.swift",
    "ClientQueryCursor.swift",
    "DatabaseContext.swift",
    "FeatureQueryResults.swift",
    "FullTextQueryBuilder.swift",
    "Internal",
    "PolymorphicQueryBuilder.swift",
    "PredicateOperators.swift",
    "QueryBuilder.swift",
    "QueryResult.swift",
    "SaveOptions.swift",
    "TypedCommand.swift",
    "VectorQueryBuilder.swift",
]

let hostTestExcludes = [
    "CanonicalReadFeatureTests.swift",
    "DatabaseClientE2ETests.swift",
    "DatabaseClientTests.swift",
    "WebSocketTransportLifecycleTests.swift",
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
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/database-kit.git", from: "26.0613.0"),
    ],
    targets: [
        .target(
            name: "DatabaseClient",
            dependencies: wireClientEnabled
                ? [
                    .product(name: "DatabaseKitWasmCore", package: "database-kit"),
                ]
                : [
                    .product(name: "Core", package: "database-kit"),
                    .product(name: "QueryIR", package: "database-kit"),
                    .product(name: "DatabaseClientProtocol", package: "database-kit"),
                    .product(name: "Vector", package: "database-kit"),
                    .product(name: "FullText", package: "database-kit"),
                    .product(name: "Permuted", package: "database-kit"),
                ],
            exclude: wireClientEnabled ? hostSourceExcludes : ["Wire"]
        ),
        .testTarget(
            name: "DatabaseClientTests",
            dependencies: wireClientEnabled
                ? [
                    "DatabaseClient",
                    .product(name: "DatabaseKitWasmCore", package: "database-kit"),
                ]
                : ["DatabaseClient"],
            exclude: wireClientEnabled ? hostTestExcludes : ["Wire"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
